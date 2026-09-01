#!/bin/sh

umask 077

sms_forward_read_input()
{
	local input

	input=$(cat) || return 1
	[ -n "$input" ] || return 1
	API_CONFIG=$(printf '%s' "$input" | jq -ce '.api_config // {}') || return 1
	SMS_SENDER=$(printf '%s' "$input" | jq -r '.sender // ""') || return 1
	SMS_TIME=$(printf '%s' "$input" | jq -r '.time // ""') || return 1
	SMS_CONTENT=$(printf '%s' "$input" | jq -r '.content // ""') || return 1
	unset input
}

sms_forward_curl_escape()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Keep provider URLs, authorization headers and message bodies out of argv.
# The URL/header are stored in a mode-0600 transient curl config; POST data is
# streamed over stdin. curl is a hard dependency of sms-forwarder-next.
sms_forward_curl_request()
{
	local method="$1"
	local url="$2"
	local content_type="$3"
	local payload="$4"
	local extra_header="$5"
	local curl_config rc

	command -v curl >/dev/null 2>&1 || return 127
	[ -n "$url" ] || return 1
	if printf '%s%s' "$url" "$extra_header" | LC_ALL=C grep -q '[[:cntrl:]]'; then
		return 1
	fi

	curl_config=$(mktemp /tmp/sms-forward-curl.XXXXXX) || return 1
	chmod 0600 "$curl_config" || {
		rm -f "$curl_config"
		return 1
	}
	{
		printf 'url = "%s"\n' "$(sms_forward_curl_escape "$url")"
		printf 'silent\nshow-error\noutput = "/dev/null"\n'
		printf 'connect-timeout = 10\nmax-time = 30\n'
		if [ "$method" = "POST" ]; then
			printf 'request = "POST"\n'
			[ -z "$content_type" ] || printf 'header = "Content-Type: %s"\n' "$(sms_forward_curl_escape "$content_type")"
		fi
		[ -z "$extra_header" ] || printf 'header = "%s"\n' "$(sms_forward_curl_escape "$extra_header")"
	} > "$curl_config" || {
		rm -f "$curl_config"
		return 1
	}

	if [ "$method" = "POST" ]; then
		printf '%s' "$payload" | curl --config "$curl_config" --data-binary @-
		rc=$?
	else
		curl --config "$curl_config"
		rc=$?
	fi
	: > "$curl_config"
	rm -f "$curl_config"
	return "$rc"
}
