#!/usr/bin/env bash

set -euo pipefail

QMODEM_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/vendor/huawei.sh"
CMDS="$QMODEM_PACKAGE_DIR/files/usr/share/qmodem/cmds/huawei.sh"

# Load only the new helpers; sourcing the full vendor needs OpenWrt jshn.
eval "$(sed -n '/^huawei_dsflow_payload()/,/^_get_lockband_nr()/p' "$VENDOR" | sed '$d')"
eval "$(sed -n '/^huawei_read_sim_slot()/,/^set_sim_slot()/p' "$VENDOR" | sed '$d')"
. "$CMDS"

inline='^DSFLOWQRY: 0000002D,0000000000019A01,0000000000736A52,0000002D,0000000000019A01,0000000000736A52
OK'
newline='^DSFLOWQRY:
0000003A,0000000000015863,0000000000834B41,0000003A,0000000000015863,0000000000834B41
OK'

[[ "$(printf '%s\n' "$inline" | huawei_dsflow_payload)" == \
    '0000002D,0000000000019A01,0000000000736A52,0000002D,0000000000019A01,0000000000736A52' ]]
[[ "$(printf '%s\n' "$newline" | huawei_dsflow_payload)" == \
    '0000003A,0000000000015863,0000000000834B41,0000003A,0000000000015863,0000000000834B41' ]]
[[ "$(huawei_hex_flow_to_dec 0000000000736A52)" == 7563858 ]]

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"; rm -f "$STATE_DIR.link"' EXIT
QMODEM_SPEED_STATE_DIR="$STATE_DIR"
AT_LOG="$STATE_DIR/at.log"
: > "$AT_LOG"
config_section='mt5700/unsafe name'
pdp_index=1
at_port=/dev/mock-at
AT_RESPONSE='^DSFLOWQRY:
00000001,00000000000003E8,00000000000007D0,00000001,00000000000003E8,00000000000007D0
OK'
SPEED_ENTRIES=

at()
{
    printf '%s\n' "$2" >> "$AT_LOG"
    printf '%s\n' "$AT_RESPONSE"
}

add_speed_entry()
{
    SPEED_ENTRIES="${SPEED_ENTRIES}${1}=${2} "
}

QMODEM_SPEED_NOW=100 network_info
[[ "$SPEED_ENTRIES" == 'rx=0 tx=0 ' ]]
[[ "$(cat "$AT_LOG")" == 'AT^DSFLOWQRY=1' ]]

AT_RESPONSE='^DSFLOWQRY: 00000003,00000000000005DC,0000000000000DAC,00000003,00000000000005DC,0000000000000DAC
OK'
SPEED_ENTRIES=
QMODEM_SPEED_NOW=102 network_info
[[ "$SPEED_ENTRIES" == 'rx=6000 tx=2000 ' ]]

# A reset counter must be sampled as zero, never as a negative/spike.
AT_RESPONSE='^DSFLOWQRY: 1,1,1,1,1,1
OK'
SPEED_ENTRIES=
QMODEM_SPEED_NOW=112 network_info
[[ "$SPEED_ENTRIES" == 'rx=0 tx=0 ' ]]

# Exercise no-CID fallback and PDP validation.
pdp_index=99
: > "$AT_LOG"
at()
{
    printf '%s\n' "$2" >> "$AT_LOG"
    [ "$(wc -l < "$AT_LOG")" -eq 1 ] && printf 'ERROR\n' || printf '%s\n' "$AT_RESPONSE"
}
SPEED_ENTRIES=
QMODEM_SPEED_NOW=122 network_info
[[ "$(cat "$AT_LOG")" == $'AT^DSFLOWQRY=1\nAT^DSFLOWQRY' ]]

[[ "$(stat -c '%a' "$STATE_DIR")" == 700 ]]
state_file="$(find "$STATE_DIR" -maxdepth 1 -type f -name 'qmodem_huawei_speed_*' -print -quit)"
[[ -n "$state_file" && "$(stat -c '%a' "$state_file")" == 600 ]]
ln -s "$STATE_DIR" "$STATE_DIR.link"
QMODEM_SPEED_STATE_DIR="$STATE_DIR.link"
! huawei_runtime_state_dir >/dev/null 2>&1

QMODEM_SPEED_STATE_DIR="$STATE_DIR"
huawei_write_sim_slot 1
[[ "$(huawei_read_sim_slot)" == 1 ]]
[[ "$(stat -c '%a' "$STATE_DIR/huawei_sim_slot")" == 600 ]]
! huawei_write_sim_slot $'1\n* * * * * /bin/false'

unset QMODEM_SPEED_STATE_DIR
config_section='../bad'
! huawei_runtime_state_dir >/dev/null 2>&1
config_section=$'modem0\n../../bad'
! huawei_runtime_state_dir >/dev/null 2>&1

printf 'PASS: Huawei MT5700 speed uses locked DSFLOWQRY bps deltas\n'
