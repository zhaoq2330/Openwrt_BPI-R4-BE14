#!/bin/sh
# Copyright (C) 2024 Tom <fjrcn@outlook.com>
umask 077
. "${QMODEM_LIB_FUNCTIONS:-/lib/functions.sh}"
. "${QMODEM_HOME:-/usr/share/qmodem}/cmds/modem_util.sh"

qmodem_valid_config_section()
{
  local section="$1"

  [ -n "$section" ] && [ "${#section}" -le 64 ] || return 1
  case "$section" in
    [A-Za-z0-9_]* ) ;;
    * ) return 1 ;;
  esac
  case "$section" in
    *[!A-Za-z0-9_-]* ) return 1 ;;
  esac
}

qmodem_runtime_section_dir()
{
  local section="${1:-${config_section:-}}"
  local runtime_root="${QMODEM_RUNTIME_ROOT:-/var/run/qmodem}"
  local section_dir

  qmodem_valid_config_section "$section" || return 1
  case "$runtime_root" in
    /*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$runtime_root" ] || return 1
  if [ -e "$runtime_root" ]; then
    [ -d "$runtime_root" ] || return 1
  else
    mkdir -p "$runtime_root" 2>/dev/null || return 1
  fi
  chown root:root "$runtime_root" 2>/dev/null || return 1
  chmod 0700 "$runtime_root" 2>/dev/null || return 1

  section_dir="${runtime_root}/${section}_dir"
  [ ! -L "$section_dir" ] || return 1
  if [ -e "$section_dir" ]; then
    [ -d "$section_dir" ] || return 1
  else
    mkdir "$section_dir" 2>/dev/null || {
      [ ! -L "$section_dir" ] && [ -d "$section_dir" ] || return 1
    }
  fi
  chown root:root "$section_dir" 2>/dev/null || return 1
  chmod 0700 "$section_dir" 2>/dev/null || return 1
  printf '%s\n' "$section_dir"
}

qmodem_neighborcell_tempfile()
{
  local section_dir

  section_dir=$(qmodem_runtime_section_dir "${1:-${config_section:-}}") || return 1
  ( umask 077; mktemp "${section_dir}/.neighborcell.XXXXXX" )
}

qmodem_cache_file_is_safe()
{
  local cache_file="$1" cache_dir="${QMODEM_RPC_CACHE_DIR:-}" cache_meta

  case "$cache_dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$cache_file" in
    "$cache_dir"/cache_*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$cache_file" ] && [ -f "$cache_file" ] || return 1
  cache_meta=$(stat -c '%u:%a:%h' "$cache_file" 2>/dev/null) || return 1
  [ "$cache_meta" = "0:600:1" ]
}

qmodem_cache_file_is_fresh()
{
  local cache_file="$1" cache_timeout="$2" current_time="$3" file_time

  qmodem_cache_file_is_safe "$cache_file" || return 1
  file_time=$(stat -c '%Y' "$cache_file" 2>/dev/null) || return 1
  [ "$file_time" -le "$current_time" ] || return 1
  [ $((current_time - file_time)) -le "$cache_timeout" ]
}

qmodem_cache_tempfile()
{
  local cache_dir="${QMODEM_RPC_CACHE_DIR:-}" cache_dir_meta

  case "$cache_dir" in
    /*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$cache_dir" ] && [ -d "$cache_dir" ] || return 1
  cache_dir_meta=$(stat -c '%u:%a' "$cache_dir" 2>/dev/null) || return 1
  [ "$cache_dir_meta" = "0:700" ] || return 1
  ( umask 077; mktemp "$cache_dir/.cache.XXXXXX" )
}

qmodem_cache_commit()
{
  local cache_tmp="$1" cache_file="$2" cache_dir="${QMODEM_RPC_CACHE_DIR:-}"

  case "$cache_tmp" in
    "$cache_dir"/.cache.*) ;;
    *) return 1 ;;
  esac
  case "$cache_file" in
    "$cache_dir"/cache_*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$cache_tmp" ] && [ -f "$cache_tmp" ] || return 1
  chmod 0600 "$cache_tmp" || return 1
  mv -f "$cache_tmp" "$cache_file"
}

#testcase collection (fixture) support
#switch: uci set qmodem.main.testcase_collect=1 (cached per process)
#env overrides (used by tests): QMODEM_COLLECT_TESTCASE / QMODEM_COLLECT_DIR
qmodem_testcase_collect_enabled()
{
  if [ -n "${QMODEM_COLLECT_TESTCASE:-}" ]; then
    [ "$QMODEM_COLLECT_TESTCASE" = "1" ]
    return
  fi
  if [ -z "${_testcase_collect_cache:-}" ]; then
    local switch
    switch=$(uci -q get qmodem.main.testcase_collect 2>/dev/null)
    [ "$switch" = "1" ] && _testcase_collect_cache=1 || _testcase_collect_cache=0
  fi
  [ "$_testcase_collect_cache" = "1" ]
}

#record one AT exchange as a fixture json file; never fails the caller
#$1: tool (at/fastat)  $2: command  $3: raw response file  $4: exit code
qmodem_testcase_path_segment()
{
  local value="$1" fallback="$2" slug
  [ -n "$value" ] || value="$fallback"
  slug=$(printf '%s' "$value" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_' | cut -c1-40)
  [ -n "$slug" ] || slug="$fallback"
  printf '%s' "$slug"
}

qmodem_testcase_profile_dir()
{
  local collect_dir="${QMODEM_COLLECT_DIR:-/tmp/qmodem/testcases}"
  local vendor_name="${vendor:-${manufacturer:-core}}"
  local platform_name="${platform:-unknown}"
  local model_name="${QMODEM_TESTCASE_MODEL:-}"
  local vendor_slug platform_slug model_slug model_hash section_slug
  [ -n "$model_name" ] || model_name=$(uci -q get "qmodem.${config_section:-}.name" 2>/dev/null)
  [ -n "$model_name" ] || model_name="unknown"
  if [ "$vendor_name" = "core" ] || [ "$vendor_name" = "unknown" ] || [ "$model_name" = "unknown" ]; then
    section_slug=$(qmodem_testcase_path_segment "${config_section:-unknown}" unknown)
    printf '%s/recognition/pending/%s' "$collect_dir" "$section_slug"
    return
  fi
  vendor_slug=$(qmodem_testcase_path_segment "$vendor_name" core)
  platform_slug=$(qmodem_testcase_path_segment "$platform_name" unknown)
  model_slug=$(qmodem_testcase_path_segment "$model_name" unknown)
  if [ "$model_name" != "unknown" ]; then
    model_hash=$(printf '%s' "$model_name" | md5sum | cut -c1-8)
    model_slug="${model_slug}-${model_hash}"
  fi
  printf '%s/%s/%s/%s' "$collect_dir" "$vendor_slug" "$platform_slug" "$model_slug"
}

# Credentials carried by AT commands must never be written to fixture files.
qmodem_at_command_is_sensitive()
{
  case "$1" in
    AT+CPIN=*|AT+CGDCONT=*|AT+MGAUTH=*|AT^AUTHDATA=*|AT+QICSGP=*|AT*AUTH*=*)
      return 0
      ;;
  esac
  return 1
}

qmodem_record_testcase_file()
{
  local tool="$1" atcmd="$2" response_file="$3" rc="$4" response_hex
  local vendor_name="${vendor:-${manufacturer:-core}}"
  local platform_name="${platform:-unknown}"
  local model_name="${QMODEM_TESTCASE_MODEL:-}" dir phase=vendor
  local slug hash file
  qmodem_at_command_is_sensitive "$atcmd" && return 0
  [ -n "$model_name" ] || model_name=$(uci -q get "qmodem.${config_section:-}.name" 2>/dev/null)
  [ -n "$model_name" ] || model_name="unknown"
  if [ "$vendor_name" = "core" ] || [ "$vendor_name" = "unknown" ] || [ "$model_name" = "unknown" ]; then
    phase=recognition
  fi
  dir=$(qmodem_testcase_profile_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 0700 "$dir" 2>/dev/null || return 0
  slug=$(printf '%s' "$atcmd" | tr -c 'A-Za-z0-9' '_' | cut -c1-40)
  hash=$(printf '%s' "$atcmd" | md5sum | cut -c1-8)
  file="${dir}/${slug}-${hash}.json"
  response_hex=$(xxd -p "$response_file" | tr -d '\n') || return 0
  jq -n \
    --arg vendor "$vendor_name" \
    --arg platform "$platform_name" \
    --arg model "$model_name" \
    --arg command "$atcmd" \
    --arg response_hex "$response_hex" \
    --arg tool "$tool" \
    --arg phase "$phase" \
    --arg config_section "${config_section:-unknown}" \
    --argjson rc "$rc" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{vendor:$vendor, platform:$platform, model:$model, phase:$phase,
      config_section:$config_section, command:$command,
      response_hex:$response_hex, tool:$tool, rc:$rc, timestamp:$timestamp}' \
    > "$file" 2>/dev/null || rm -f "$file"
  [ ! -f "$file" ] || chmod 0600 "$file"
}

at()
{
  local at_port=$1
  local new_str="${2/[$]/$}"
  local atcmd="${new_str/\"/\"}"
  [ "$clear_buffer" == "1" ] && options="$options -M"
  #过滤空行
  if qmodem_testcase_collect_enabled; then
    local response_file rc
    response_file=$(mktemp /tmp/qmodem_at_response.XXXXXX) || {
      if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
        printf '%s\n' "$atcmd" | sms_tool_q -d "$at_port" at -
      else
        printf '%s\n' "$atcmd" | tom_modem $use_ubus_flag -d "$at_port" -o a -c - $options
      fi
      return $?
    }
    if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
     printf '%s\n' "$atcmd" | sms_tool_q -d "$at_port" at - > "$response_file"
    else
     printf '%s\n' "$atcmd" | tom_modem $use_ubus_flag -d "$at_port" -o a -c - $options > "$response_file"
    fi
    rc=$?
    qmodem_record_testcase_file "at" "$atcmd" "$response_file" "$rc"
    cat "$response_file"
    rm -f "$response_file"
    return $rc
  fi
  if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
   printf '%s\n' "$atcmd" | sms_tool_q -d "$at_port" at -
  else
   printf '%s\n' "$atcmd" | tom_modem $use_ubus_flag -d "$at_port" -o a -c - $options
  fi
}

fastat()
{
  local at_port=$1
  local new_str="${2/[$]/$}"
  local atcmd="${new_str/\"/\"}"
  #过滤空行
  if qmodem_testcase_collect_enabled; then
    local response_file rc
    response_file=$(mktemp /tmp/qmodem_at_response.XXXXXX) || {
      if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
        printf '%s\n' "$atcmd" | sms_tool_q -t 1 -d "$at_port" at -
      else
        printf '%s\n' "$atcmd" | tom_modem -d "$at_port" -o a -c - -t 1
      fi
      return $?
    }
    if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
     printf '%s\n' "$atcmd" | sms_tool_q -t 1 -d "$at_port" at - > "$response_file"
    else
     printf '%s\n' "$atcmd" | tom_modem -d "$at_port" -o a -c - -t 1 > "$response_file"
    fi
    rc=$?
    qmodem_record_testcase_file "fastat" "$atcmd" "$response_file" "$rc"
    cat "$response_file"
    rm -f "$response_file"
    return $rc
  fi
  if [ "$(uci get qmodem.main.at_tool 2>/dev/null)" == "1" ]; then
   printf '%s\n' "$atcmd" | sms_tool_q -t 1 -d "$at_port" at -
  else
   printf '%s\n' "$atcmd" | tom_modem -d "$at_port" -o a -c - -t 1
  fi
}

log2file()
{
	local subject="$1"
    local msg="$2"
	local path="$3"

	#打印日志
    local update_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${update_time}] ${subject}:${msg} " >> "${path}"
}

log2sys()
{
    local subject="$1"
    local msg="$2"
    logger -t "$subject" "$msg"
}

m_debug ()
{
	[ -z "${debug_subject:-}" ] && subject="modem_util" || subject="$debug_subject"
	[ -n "${direct_debug:-}" ] && echo "$subject" "$1"
	if [ -n "${log_file:-}" ];then
		log2file "$subject" "$1" "$log_file"
	else
		log2sys "$subject" "$1"
	fi
}

qmodem_bool_enabled()
{
	case "$1" in
		1|true|TRUE|True|yes|YES|on|ON)
			return 0
			;;
	esac
	return 1
}

qmodem_lockcell_boot_hook_clear()
{
	local section="$1"

	[ -z "$section" ] && return 1
	uci -q delete "qmodem.${section}.lockcell_boot_hook_enabled"
	uci -q delete "qmodem.${section}.lockcell_boot_hook_delay"
	uci -q delete "qmodem.${section}.lockcell_boot_hook_at_cmds"
	uci commit qmodem >/dev/null 2>&1
}

qmodem_lockcell_boot_hook_save()
{
	local section="$1"
	local delay="$2"
	local cmd

	shift 2
	[ -z "$section" ] && return 1
	[ -z "$delay" ] && delay="15"

	uci -q delete "qmodem.${section}.lockcell_boot_hook_at_cmds"
	uci -q set "qmodem.${section}.lockcell_boot_hook_enabled=1" || return 1
	uci -q set "qmodem.${section}.lockcell_boot_hook_delay=${delay}" || return 1

	for cmd in "$@"; do
		if [ -n "$cmd" ]; then
			uci -q add_list "qmodem.${section}.lockcell_boot_hook_at_cmds=${cmd}" || return 1
		fi
	done

	uci commit qmodem >/dev/null 2>&1
}

qmodem_lockcell_boot_hook_add_json()
{
	local section="$1"
	local enabled delay
	local has_cmds=0

	enabled=$(uci -q get "qmodem.${section}.lockcell_boot_hook_enabled")
	delay=$(uci -q get "qmodem.${section}.lockcell_boot_hook_delay")
	[ -z "$delay" ] && delay="15"
	config_load qmodem
	config_list_foreach "$section" lockcell_boot_hook_at_cmds qmodem_lockcell_mark_list_cmd

	json_add_object "lockcell_boot_hook"
	if qmodem_bool_enabled "$enabled" && [ "$has_cmds" = "1" ]; then
		json_add_boolean "enabled" 1
	else
		json_add_boolean "enabled" 0
	fi
	json_add_string "delay" "$delay"
	json_add_array "at_cmds"
	config_list_foreach "$section" lockcell_boot_hook_at_cmds qmodem_json_add_list_string
	json_close_array
	json_close_object
}

qmodem_lockcell_mark_list_cmd()
{
	[ -n "$1" ] && has_cmds=1
}

qmodem_json_add_list_string()
{
	[ -n "$1" ] && json_add_string "" "$1"
}

qmodem_lockcell_boot_hook_sync()
{
	local section="$1"
	local en_boot_hook="$2"

	shift 2
	if qmodem_bool_enabled "$en_boot_hook"; then
		[ -z "$*" ] && qmodem_lockcell_boot_hook_clear "$section" && return
		qmodem_lockcell_boot_hook_save "$section" 15 "$@"
	else
		qmodem_lockcell_boot_hook_clear "$section"
	fi
}

update_sim_slot()
{
	. /lib/functions.sh
	board=$(board_name)
	case $board in
		HC,HC-G80*)
			sim_pin="/sys/class/gpio/sim/value"
			sim_pin_value=$(cat $sim_pin)
			[ "$sim_pin_value" == "0" ] && sim_slot="2" || sim_slot="1"
			#电平高表示SIM卡在卡槽1，电平低表示SIM卡在卡槽2
			debug "update_sim_slot:sim_slot=$sim_slot"
			;;
		ailf,gs2410|\
		huasifei,ws3006)
			sim_pin="/sys/class/gpio/dual_sim/value"
			#电平高则都在卡槽1，电平低则需要使用at查询
			[ "$(cat $sim_pin)" == "1" ] && sim_slot="1" || at_get_slot
			;;
		*)
			at_get_slot
			;;
	esac
}

at_get_slot()
{
	case $vendor in
		"quectel")
			at_res=$(cmd_util_quimslot_query "$at_port" | awk -F':' '/\+(QUIMSLOT|QUSIMSLOT):/ {
				value=$2
				gsub(/[^0-9]/, "", value)
				print value
				exit
			}')
			case "$at_res" in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			esac
			;;
		"fibocom")
			at_res=$(cmd_util_gtdualsim_query "$at_port" |grep +GTDUALSIM: |awk -F: '{print $2}')
			case $at_res in
				"0")
					sim_slot="1"
					;;
				"1")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"simcom")
			at_res=$(cmd_util_smsimcfg_query "$at_port" | grep "+SMSIMCFG:" | awk -F',' '{print $2}' | sed 's/\r//g')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"meig")
			at_res=$(cmd_util_simslot_query "$at_port" | grep "\^SIMSLOT:" | awk -F': ' '{print $2}' | awk -F',' '{print $2}')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"0")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"neoway")
			at_res=$(cmd_util_simcross_query "$at_port" | grep "+SIMCROSS:" | awk -F'[ ,]' '{print $2}' | sed 's/\r//g')
			case $at_res in
				"1")
					sim_slot="1"
					;;
				"2")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		"telit")
			at_res=$(cmd_util_qss_query "$at_port" | grep "#QSS:" | awk -F',' '{print $3}' | sed 's/\r//g')
			case $at_res in
				"0")
					sim_slot="1"
					;;
				"1")
					sim_slot="2"
					;;
				*)
					sim_slot="1"
					;;
			*)
				sim_slot="1"
				;;
			esac
			;;
		*)
			at_q_res=$(cmd_util_qsimdet_query "$at_port" |grep +QSIMDET: |awk -F: '{print $2}')
			at_f_res=$(cmd_util_gtdualsim_query "$at_port" |grep +GTDUALSIM: |awk -F: '{print $2}')
			[ "$at_q_res" == "1" ] && sim_slot="1" && return
			[ "$at_q_res" == "2" ] && sim_slot="2" && return
			[ "$at_f_res" == "0" ] && sim_slot="1" && return
			[ "$at_f_res" == "1" ] && sim_slot="2" && return
			sim_slot="1"
		;;

	esac
}
