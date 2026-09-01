#!/usr/bin/env bash

set -euo pipefail

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC="$QMODEM_PACKAGE_DIR/files/usr/libexec/rpcd/qmodem"
LEGACY="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/modem_ctrl.sh"
BOARD="$QMODEM_PACKAGE_DIR/files/etc/uci-defaults/99-qmodem-board"
LED="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/led_scripts/misectel_3led.sh"

eval "$(sed -n '/^valid_config_section()/,/^}/p' "$RPC")"
eval "$(sed -n '/^require_modem_config_section()/,/^}/p' "$RPC")"

uci()
{
	case "$*" in
		'-q get qmodem.modem0') printf '%s\n' modem-device ;;
		'-q get qmodem.not_modem') printf '%s\n' main ;;
	esac
}

for section in modem0 modem_1 modem-2 A; do
	valid_config_section "$section" || {
		echo "valid section rejected: $section" >&2
		exit 1
	}
done

newline_section="$(printf 'modem0\n* * * * * /bin/false')"
for section in '' '-leading' '../etc' 'modem/../../etc' 'modem name' \
	"modem'quote" "$newline_section"; do
	if valid_config_section "$section"; then
		echo "unsafe section accepted" >&2
		exit 1
	fi
done

section_64="a$(printf '%063d' 0)"
section_65="a$(printf '%064d' 0)"
valid_config_section "$section_64"
! valid_config_section "$section_65"
require_modem_config_section modem0
! require_modem_config_section not_modem
! require_modem_config_section "$newline_section"

# The main RPC must reject config_section before dispatch reaches UCI-backed
# path or root-crontab writers. The legacy helper must no longer use /tmp for
# response caches or its former reboot debug file.
validator_line="$(grep -n 'require_modem_config_section.*invalid_config_section' "$RPC" | head -n1 | cut -d: -f1)"
dispatch_line="$(grep -n 'traffic_reset_set_schedule.*input' "$RPC" | tail -n1 | cut -d: -f1)"
[[ -n "$validator_line" && -n "$dispatch_line" && "$validator_line" -lt "$dispatch_line" ]]
! grep -Eq '/tmp/cache_|/tmp/555' "$RPC" "$LEGACY"
grep -Fq 'QMODEM_RPC_CACHE_DIR="/var/run/qmodem/rpcd"' "$LEGACY"
! grep -Fq '/tmp/qmodem-board' "$BOARD"
grep -Fq 'board_tmp="$(mktemp /etc/.qmodem-board.XXXXXX)"' "$BOARD"
grep -Fq 'mv "$board_tmp" "$BOARD_FILE" || {' "$BOARD"
! grep -Fq '/tmp/cache_cell_info' "$LED"
grep -Fq '/var/run/qmodem/rpcd/cache_cell_info_${MODEM_CFG}' "$LED"

# rpcd supplies exactly one JSON document on stdin. Every method must reuse
# the single payload read at the call entry instead of attempting a second
# read after stdin has reached EOF (which broke all SMS mutation methods).
[[ "$(grep -Fc 'read -r input' "$RPC")" -eq 1 ]]

printf 'PASS: QModem RPC rejects path/newline/cron config sections\n'
