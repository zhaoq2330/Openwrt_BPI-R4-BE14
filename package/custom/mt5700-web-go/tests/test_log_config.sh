#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/files/etc/init.d/mt5700-web"
CONFIG="$ROOT/files/etc/config/mt5700-web"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

# shellcheck source=/dev/null
. "$INIT"

migrate_legacy_instance() { :; }
config_load() { :; }
config_get_bool() {
	case "$1" in
		enabled) enabled=1 ;;
		*) eval "$1=\$4" ;;
	esac
}
config_get() {
	case "$1" in
		log_max_bytes) log_max_bytes="$TEST_LOG_MAX" ;;
		log_backups) log_backups="$TEST_LOG_BACKUPS" ;;
		*) eval "$1=\$4" ;;
	esac
}
procd_open_instance() { :; }
procd_set_param() { :; }
procd_append_param() {
	[ "$1" = command ] || return 0
	shift
	for argument in "$@"; do
		printf '<%s>\n' "$argument" >> "$TEST_ROOT/command"
	done
}
procd_close_instance() { :; }

run_case() {
	TEST_LOG_MAX="$1"
	TEST_LOG_BACKUPS="$2"
	: > "$TEST_ROOT/command"
	start_service
}

run_case 999999999999999999999 99
grep -Fqx '<16777216>' "$TEST_ROOT/command"
grep -Fqx '<8>' "$TEST_ROOT/command"

run_case "1
2" "4
5"
grep -Fqx '<2097152>' "$TEST_ROOT/command"
grep -Fqx '<3>' "$TEST_ROOT/command"

if grep -Fq -- '-log-file' "$INIT" || grep -Fq 'log_file' "$CONFIG"; then
	echo 'FAIL: mutable log path is still exposed through UCI/init' >&2
	exit 1
fi

echo 'MT5700 log configuration tests passed'
