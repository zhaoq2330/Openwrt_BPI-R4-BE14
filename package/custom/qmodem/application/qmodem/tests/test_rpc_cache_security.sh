#!/usr/bin/env bash

set -euo pipefail
umask 077

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UTIL="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/modem_util.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

eval "$(sed -n '/^qmodem_cache_file_is_safe()/,/^#testcase collection/p' "$UTIL" | sed '$d')"

QMODEM_RPC_CACHE_DIR="$TEST_ROOT/runtime"
mkdir "$QMODEM_RPC_CACHE_DIR"
chmod 0700 "$QMODEM_RPC_CACHE_DIR"

cache_file="$QMODEM_RPC_CACHE_DIR/cache_info_modem0"
cache_tmp="$(qmodem_cache_tempfile)"
printf '%s\n' '{"state":"new"}' > "$cache_tmp"
[[ "$(stat -c '%a' "$cache_tmp")" == 600 ]]
qmodem_cache_commit "$cache_tmp" "$cache_file"
qmodem_cache_file_is_safe "$cache_file"
qmodem_cache_file_is_fresh "$cache_file" 10 "$(date +%s)"
[[ "$(cat "$cache_file")" == '{"state":"new"}' ]]

# A writer only publishes its complete temporary file at rename time, so a
# concurrent reader continues to see the previous complete JSON document.
cache_tmp="$(qmodem_cache_tempfile)"
printf '%s' '{"state":' > "$cache_tmp"
[[ "$(cat "$cache_file")" == '{"state":"new"}' ]]
printf '%s\n' '"complete"}' >> "$cache_tmp"
qmodem_cache_commit "$cache_tmp" "$cache_file"
[[ "$(cat "$cache_file")" == '{"state":"complete"}' ]]

# Replacing a hostile symlink or hard link must not modify its target.
victim="$TEST_ROOT/victim"
printf '%s\n' keep > "$victim"
ln -s "$victim" "$QMODEM_RPC_CACHE_DIR/cache_sms_modem0"
cache_tmp="$(qmodem_cache_tempfile)"
printf '%s\n' '[]' > "$cache_tmp"
qmodem_cache_commit "$cache_tmp" "$QMODEM_RPC_CACHE_DIR/cache_sms_modem0"
[[ "$(cat "$victim")" == keep ]]
[[ ! -L "$QMODEM_RPC_CACHE_DIR/cache_sms_modem0" ]]

hard_victim="$TEST_ROOT/hard-victim"
printf '%s\n' hard-keep > "$hard_victim"
chmod 0600 "$hard_victim"
ln "$hard_victim" "$QMODEM_RPC_CACHE_DIR/cache_cell_modem0"
! qmodem_cache_file_is_safe "$QMODEM_RPC_CACHE_DIR/cache_cell_modem0"
cache_tmp="$(qmodem_cache_tempfile)"
printf '%s\n' '{}' > "$cache_tmp"
qmodem_cache_commit "$cache_tmp" "$QMODEM_RPC_CACHE_DIR/cache_cell_modem0"
[[ "$(cat "$hard_victim")" == hard-keep ]]
[[ "$(stat -c '%h' "$hard_victim")" == 1 ]]

# Refuse runtime directories that are writable by other users or symlinks.
chmod 0755 "$QMODEM_RPC_CACHE_DIR"
! qmodem_cache_tempfile >/dev/null 2>&1
chmod 0700 "$QMODEM_RPC_CACHE_DIR"
mv "$QMODEM_RPC_CACHE_DIR" "$TEST_ROOT/real-runtime"
ln -s "$TEST_ROOT/real-runtime" "$QMODEM_RPC_CACHE_DIR"
! qmodem_cache_tempfile >/dev/null 2>&1

printf 'PASS: QModem RPC caches use safe atomic replacement\n'
