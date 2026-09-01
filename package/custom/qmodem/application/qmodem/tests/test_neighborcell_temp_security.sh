#!/usr/bin/env bash

set -euo pipefail
umask 077

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UTIL="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/modem_util.sh"
VENDOR_DIR="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/vendor"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

[[ "$(grep -c 'chown root:root' "$UTIL")" -ge 2 ]]
if [[ "$EUID" -ne 0 ]]; then
	chown() { return 0; }
fi
eval "$(sed -n '/^qmodem_valid_config_section()/,/^#testcase collection/p' "$UTIL" | sed '$d')"

for vendor in simcom fibocom quectel; do
	file="$VENDOR_DIR/$vendor.sh"
	! grep -Fq '/tmp/neighborcell' "$file"
	done_count="$(grep -c 'qmodem_neighborcell_tempfile' "$file")"
	cleanup_count="$(grep -c 'rm -f "$neighborcell_file"' "$file")"
	case "$vendor" in
		simcom|fibocom) expected=1 ;;
		quectel) expected=3 ;;
	esac
	[[ "$done_count" -eq "$expected" && "$cleanup_count" -eq "$expected" ]]
done

TARGET_DIR="$TEST_ROOT/target"
mkdir "$TARGET_DIR"

# Refuse a hostile runtime-root symlink.
ln -s "$TARGET_DIR" "$TEST_ROOT/runtime-link"
QMODEM_RUNTIME_ROOT="$TEST_ROOT/runtime-link"
! qmodem_neighborcell_tempfile modem0 >/dev/null 2>&1
[[ -z "$(find "$TARGET_DIR" -mindepth 1 -print -quit)" ]]

# Refuse a hostile per-section symlink and path/newline section names.
QMODEM_RUNTIME_ROOT="$TEST_ROOT/runtime"
mkdir "$QMODEM_RUNTIME_ROOT"
ln -s "$TARGET_DIR" "$QMODEM_RUNTIME_ROOT/modem0_dir"
! qmodem_neighborcell_tempfile modem0 >/dev/null 2>&1
rm "$QMODEM_RUNTIME_ROOT/modem0_dir"
! qmodem_neighborcell_tempfile '../bad' >/dev/null 2>&1
! qmodem_neighborcell_tempfile $'modem0\n../../bad' >/dev/null 2>&1

# Concurrent calls for the same modem must receive distinct mode-0600 files.
for index in $(seq 1 16); do
	(
		path="$(qmodem_neighborcell_tempfile modem0)"
		printf '%s\n' "$index" > "$path"
		printf '%s\n' "$path" > "$TEST_ROOT/path.$index"
	) &
done
wait

[[ "$(cat "$TEST_ROOT"/path.* | wc -l)" -eq 16 ]]
[[ "$(cat "$TEST_ROOT"/path.* | sort -u | wc -l)" -eq 16 ]]
[[ "$(stat -c '%a' "$QMODEM_RUNTIME_ROOT")" == 700 ]]
[[ "$(stat -c '%a' "$QMODEM_RUNTIME_ROOT/modem0_dir")" == 700 ]]
for index in $(seq 1 16); do
	path="$(cat "$TEST_ROOT/path.$index")"
	[[ "$path" == "$QMODEM_RUNTIME_ROOT/modem0_dir/".neighborcell.* ]]
	[[ ! -L "$path" && -f "$path" && "$(stat -c '%a' "$path")" == 600 ]]
	[[ "$(cat "$path")" == "$index" ]]
	rm -f "$path"
done
[[ -z "$(find "$QMODEM_RUNTIME_ROOT/modem0_dir" -mindepth 1 -print -quit)" ]]

printf 'PASS: neighbor-cell temp files reject symlinks and isolate concurrent vendors\n'
