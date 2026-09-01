#!/bin/sh
set -eu

PACKAGE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_HELPER="$PACKAGE_DIR/root/usr/libexec/wan-speedtest"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/proc/self"
printf '%s\n' '1 (fixture) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123' \
	> "$TEST_ROOT/proc/self/stat"
HELPER="$TEST_ROOT/wan-speedtest"
sed \
	-e "s|^RUNTIME_DIR=.*|RUNTIME_DIR='$TEST_ROOT/run'|" \
	-e "s|^PROC_ROOT=.*|PROC_ROOT='$TEST_ROOT/proc'|" \
	-e "s|^SELF=.*|SELF='$HELPER'|" \
	-e "s|/usr/bin/librespeed-cli|$TEST_ROOT/bin/librespeed-cli|g" \
	"$SOURCE_HELPER" > "$HELPER"
chmod 0755 "$HELPER"

START_LOG="$TEST_ROOT/daemon-starts"
export START_LOG
: > "$START_LOG"

cat > "$TEST_ROOT/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
pidfile=
executable=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-p) pidfile="$2"; shift 2 ;;
		-x) executable="$2"; shift 2 ;;
		--) shift; break ;;
		*) shift ;;
	esac
done
[ -n "$pidfile" ] && [ -n "$executable" ] || exit 2
"$executable" "$@" >/dev/null 2>&1 &
worker_pid=$!
printf '%s\n' "$worker_pid" > "$pidfile"
printf 'start\n' >> "$START_LOG"
EOF
chmod 0755 "$TEST_ROOT/bin/start-stop-daemon"

cat > "$TEST_ROOT/bin/librespeed-cli" <<'EOF'
#!/bin/sh
if [ -e "$LONG_TEST_MARKER" ]; then
	printf '%s\n' "$$" > "$LONG_TEST_PID"
	exec sleep 30
fi
sleep 1
printf '%s\n' '[{"download":912.34,"upload":123.45,"ping":8.9,"jitter":1.2,"server":{"name":"fixture"}}]'
EOF
chmod 0755 "$TEST_ROOT/bin/librespeed-cli"

cat > "$TEST_ROOT/bin/jsonfilter" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$TEST_ROOT/bin/jsonfilter"

PATH="$TEST_ROOT/bin:$PATH"
export PATH
LONG_TEST_MARKER="$TEST_ROOT/long-test"
LONG_TEST_PID="$TEST_ROOT/long-test.pid"
export LONG_TEST_MARKER LONG_TEST_PID

set +e
"$HELPER" start > "$TEST_ROOT/start-one.json" &
start_one_pid=$!
"$HELPER" start > "$TEST_ROOT/start-two.json" &
start_two_pid=$!
wait "$start_one_pid"
start_one_status=$?
wait "$start_two_pid"
start_two_status=$?
set -e

case "$start_one_status:$start_two_status" in
	0:3|3:0) ;;
	*)
		echo "FAIL: concurrent start statuses were $start_one_status and $start_two_status" >&2
		printf 'start one: '; cat "$TEST_ROOT/start-one.json" >&2 || true
		printf 'start two: '; cat "$TEST_ROOT/start-two.json" >&2 || true
		exit 1
		;;
esac
[ "$(wc -l < "$START_LOG" | tr -d '[:space:]')" = 1 ] || {
	echo 'FAIL: concurrent requests spawned more than one worker' >&2
	exit 1
}

wait_for_completion() {
	attempt=0
	while [ "$attempt" -lt 50 ]; do
		if [ "$(cat "$TEST_ROOT/run/state" 2>/dev/null)" = complete ] &&
		   [ ! -e "$TEST_ROOT/run/lock" ]; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 0.1
	done
	echo 'FAIL: worker did not complete and release its ownership lock' >&2
	return 1
}

wait_for_completion

# Stop must terminate the active speed-test process itself, not merely the
# supervising shell while bandwidth consumption continues in the background.
touch "$LONG_TEST_MARKER"
"$HELPER" start > "$TEST_ROOT/long-start.json"
attempt=0
while [ ! -s "$LONG_TEST_PID" ] && [ "$attempt" -lt 50 ]; do
	attempt=$((attempt + 1))
	sleep 0.1
done
[ -s "$LONG_TEST_PID" ] || {
	echo 'FAIL: long-running speed-test process did not start' >&2
	exit 1
}
long_test_pid="$(cat "$LONG_TEST_PID")"
"$HELPER" stop > "$TEST_ROOT/long-stop.json"
attempt=0
while kill -0 "$long_test_pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
	attempt=$((attempt + 1))
	sleep 0.1
done
if kill -0 "$long_test_pid" 2>/dev/null; then
	echo 'FAIL: stop left the speed-test process running' >&2
	kill "$long_test_pid" 2>/dev/null || true
	exit 1
fi
[ "$(cat "$TEST_ROOT/run/state")" = cancelled ]
rm -f "$LONG_TEST_MARKER" "$LONG_TEST_PID"

# A dead owner (or a reused PID with a different /proc start time) must be
# recoverable under the serialized mutex, without affecting a live process.
mkdir -m 0700 "$TEST_ROOT/run/lock"
printf 'worker %s 1 stale-token\n' "$$" > "$TEST_ROOT/run/lock/owner"
chmod 0600 "$TEST_ROOT/run/lock/owner"
"$HELPER" start > "$TEST_ROOT/stale-recovery.json"
[ "$(wc -l < "$START_LOG" | tr -d '[:space:]')" = 3 ] || {
	echo 'FAIL: stale owner was not recovered exactly once' >&2
	exit 1
}
wait_for_completion

# The internal worker action is reachable through the file-exec ACL, so it
# must reject calls that do not possess the active run token.
if "$HELPER" worker '' not-the-owner >/dev/null 2>&1; then
	echo 'FAIL: internal worker accepted an unowned token' >&2
	exit 1
fi

mkdir -m 0700 "$TEST_ROOT/run/lock"
printf 'worker %s 1 reused-pid-token\n' "$$" > "$TEST_ROOT/run/lock/owner"
chmod 0600 "$TEST_ROOT/run/lock/owner"
"$HELPER" stop > "$TEST_ROOT/stop.json"
[ "$(cat "$TEST_ROOT/run/state")" = cancelled ]
[ ! -e "$TEST_ROOT/run/lock" ]

echo 'WAN speed-test concurrency and stale-owner tests passed'
