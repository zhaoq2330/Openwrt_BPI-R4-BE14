#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RPCD="$ROOT/root/usr/libexec/rpcd/luci.argon_wallpaper"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

# Load only the runtime and wallpaper helpers; the rpcd entry point depends on
# OpenWrt-specific jshn functions which are unrelated to these tests.
FUNCTIONS="$(sed -n '/^path_exists()/,/^case "$1" in/p' "$RPCD" | sed '$d')"
eval "$FUNCTIONS"

WEB_PIC_SRC=bing
RUNTIME_DIR="$TEST_ROOT/runtime"
CACHE="$RUNTIME_DIR/$WEB_PIC_SRC.url"
WRLOCK="$RUNTIME_DIR/$WEB_PIC_SRC.lock"
COUNTER="$TEST_ROOT/fetches"
TEST_URL='https://www.bing.com/test.jpg'

fetch_pic_url() {
	local delay_pid
	printf 'fetch\n' >> "$COUNTER"
	if [ "${FETCH_DELAY:-0}" != 0 ]; then
		if [ -n "${FETCH_DELAY_PID_FILE:-}" ]; then
			sleep "$FETCH_DELAY" &
			delay_pid="$!"
			printf '%s\n' "$delay_pid" > "$FETCH_DELAY_PID_FILE"
			wait "$delay_pid" || return 1
		else
			sleep "$FETCH_DELAY"
		fi
	fi
	printf '%s\n' "$TEST_URL"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A planted runtime symlink must not be traversed or modified.
mkdir "$TEST_ROOT/runtime-target"
printf 'sentinel\n' > "$TEST_ROOT/runtime-target/sentinel"
ln -s "$TEST_ROOT/runtime-target" "$RUNTIME_DIR"
init_runtime >/dev/null 2>&1 && fail 'runtime symlink was accepted'
[ "$(cat "$TEST_ROOT/runtime-target/sentinel")" = sentinel ] || fail 'runtime symlink target changed'
rm "$RUNTIME_DIR"

# Normal creation has strict ownership/mode and cache replacement is atomic.
output="$(try_update)"
[ "$output" = "$TEST_URL" ] || fail 'normal update did not return the fetched URL'
[ "$(stat -c '%u:%g:%a' "$RUNTIME_DIR")" = 0:0:700 ] || fail 'runtime mode/owner is not root:root 0700'
[ "$(stat -c '%u:%g:%a:%h' "$CACHE")" = 0:0:600:1 ] || fail 'cache mode/owner/type is unsafe'
[ "$(cat "$CACHE")" = "$TEST_URL" ] || fail 'cache content is incorrect'
[ "$(stat -c '%u:%g:%a:%h' "$WRLOCK")" = 0:0:600:1 ] || fail 'lock file mode/owner/type is unsafe'
flock -n "$WRLOCK" true || fail 'kernel lock was not released'
[ -z "$(find "$RUNTIME_DIR" -maxdepth 1 -name '.*.url.*' -print -quit)" ] || fail 'temporary cache file leaked'

# A planted cache symlink must be rejected without altering its target.
printf 'do-not-touch\n' > "$TEST_ROOT/cache-victim"
rm "$CACHE"
ln -s "$TEST_ROOT/cache-victim" "$CACHE"
try_update >/dev/null 2>&1 && fail 'cache symlink was accepted'
[ "$(cat "$TEST_ROOT/cache-victim")" = do-not-touch ] || fail 'cache symlink target changed'
rm "$CACHE"

# The lock path also rejects symlinks rather than opening their targets.
rm "$WRLOCK"
ln -s "$TEST_ROOT/cache-victim" "$WRLOCK"
try_update >/dev/null 2>&1 && fail 'lock symlink was accepted'
[ "$(cat "$TEST_ROOT/cache-victim")" = do-not-touch ] || fail 'lock symlink target changed'
rm "$WRLOCK"

# A live owner must never be reclaimed. Once that exact process is killed,
# the kernel releases its descriptor lock and a new request can acquire it in
# the same boot without deleting or replacing the safe lock file.
init_runtime || fail 'lock file recreation failed'
owner_ready="$TEST_ROOT/owner-ready"
(
	acquire_lock || exit 20
	: > "$owner_ready"
	exec sleep 30
) &
owner_pid="$!"
tries=0
while [ ! -e "$owner_ready" ]; do
	tries="$((tries + 1))"
	[ "$tries" -lt 100 ] || fail 'live owner did not acquire the lock'
	sleep 0.02
done
if acquire_lock; then
	release_lock >/dev/null 2>&1 || true
	fail 'lock was reclaimed from a live owner'
else
	[ "$?" -eq 1 ] || fail 'live owner was treated as an unsafe lock path'
fi
kill -9 "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
acquire_lock || fail 'SIGKILL left the lock unavailable for this boot'
release_lock || fail 'recovered lock could not be released'
[ "$(stat -c '%u:%g:%a:%h' "$WRLOCK")" = 0:0:600:1 ] || fail 'recovered lock file became unsafe'

# A network subprocess must not inherit fd 9. Killing the rpcd owner while its
# fetch subprocess remains alive must still make the lock immediately reusable.
: > "$COUNTER"
fetch_delay_pid_file="$TEST_ROOT/fetch-delay-pid"
(FETCH_DELAY=2 FETCH_DELAY_PID_FILE="$fetch_delay_pid_file" \
	try_update > "$TEST_ROOT/killed-fetch.out" 2> "$TEST_ROOT/killed-fetch.err") &
fetch_owner_pid="$!"
tries=0
while [ ! -s "$fetch_delay_pid_file" ]; do
	tries="$((tries + 1))"
	[ "$tries" -lt 100 ] || fail 'fetch subprocess did not start under the lock'
	sleep 0.02
done
fetch_delay_pid="$(cat "$fetch_delay_pid_file")"
case "$fetch_delay_pid" in
	''|*[!0-9]*) fail 'fetch subprocess PID is invalid' ;;
esac
kill -9 "$fetch_owner_pid"
wait "$fetch_owner_pid" 2>/dev/null || true
kill -0 "$fetch_delay_pid" 2>/dev/null || fail 'fetch subprocess did not outlive the killed lock owner'
acquire_lock || fail 'fetch subprocess inherited the killed owner lock'
release_lock || fail 'post-OOM/SIGKILL lock could not be released'
kill "$fetch_delay_pid" 2>/dev/null || true

# Exactly one concurrent request may fetch. The other observes a safe busy lock
# and returns immediately; the winner publishes one complete cache atomically.
: > "$COUNTER"
(FETCH_DELAY=1 try_update > "$TEST_ROOT/first.out") &
first_pid="$!"
tries=0
while [ ! -s "$COUNTER" ]; do
	tries="$((tries + 1))"
	[ "$tries" -lt 100 ] || fail 'first request did not acquire the lock'
	sleep 0.02
done
(try_update > "$TEST_ROOT/second.out") &
second_pid="$!"
wait "$first_pid"
wait "$second_pid"
[ "$(wc -l < "$COUNTER")" -eq 1 ] || fail 'concurrent requests fetched more than once'
[ "$(cat "$TEST_ROOT/first.out")" = "$TEST_URL" ] || fail 'lock owner returned an incomplete result'
[ ! -s "$TEST_ROOT/second.out" ] || fail 'busy request returned unvalidated data'
[ "$(cat "$CACHE")" = "$TEST_URL" ] || fail 'concurrent cache content is incorrect'
[ "$(stat -c '%u:%g:%a:%h' "$WRLOCK")" = 0:0:600:1 ] || fail 'concurrent lock file became unsafe'
flock -n "$WRLOCK" true || fail 'concurrent lock was not released'

echo 'Argon wallpaper runtime security tests passed'
