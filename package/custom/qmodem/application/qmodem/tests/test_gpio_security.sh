#!/usr/bin/env bash

set -euo pipefail

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERIC="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/generic.sh"

eval "$(sed -n '/^qmodem_valid_gpio_name()/,/^hard_reboot()/p' "$GENERIC" | sed '$d')"

for name in gpio42 4g dual_sim gpio-chip:modem; do
	qmodem_valid_gpio_name "$name"
done

newline_name=$'gpio42\n../../tmp'
for name in '' '.' '..' '../tmp' 'gpio/42' 'gpio.42' 'gpio 42' "$newline_name"; do
	! qmodem_valid_gpio_name "$name"
done

name_64="g$(printf '%063d' 0)"
name_65="g$(printf '%064d' 0)"
qmodem_valid_gpio_name "$name_64"
! qmodem_valid_gpio_name "$name_65"

qmodem_valid_gpio_level 0
qmodem_valid_gpio_level 1
for level in '' 2 -1 true $'1\n0'; do
	! qmodem_valid_gpio_level "$level"
done

! grep -Eq '>[[:space:]]*\$gpio([[:space:]]|$)' "$GENERIC"
grep -Fq 'power_gpio_path="/sys/class/gpio/${gpio}/value"' "$GENERIC"
grep -Fq 'printf '\''%s\n'\'' "$gpio_down" > "$power_gpio_path"' "$GENERIC"
grep -Fq 'printf '\''%s\n'\'' "$gpio_up" > "$power_gpio_path"' "$GENERIC"

printf 'PASS: QModem GPIO reboot rejects UCI path and value injection\n'
