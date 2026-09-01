#!/bin/sh

. /usr/share/sms_forwarder/sms_forward_common.sh
sms_forward_read_input || exit 1

# ServerChan SMS Forward Script (New API)
# Environment variables available:
# SMS_SENDER - sender phone number
# SMS_TIME - timestamp string
# SMS_CONTENT - SMS content

if [ -z "$API_CONFIG" ]; then
    echo "Error: API config not provided"
    exit 1
fi

# Extract configuration using jq or manual parsing
TOKEN=$(printf '%s' "$API_CONFIG" | jq -r '.token' 2>/dev/null)
CHANNEL=$(printf '%s' "$API_CONFIG" | jq -r '.channel' 2>/dev/null)
NOIP=$(printf '%s' "$API_CONFIG" | jq -r '.noip' 2>/dev/null)
OPENID=$(printf '%s' "$API_CONFIG" | jq -r '.openid' 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "Error: Missing required ServerChan token"
    exit 1
fi

# Build API URL with token
API_URL="https://sctapi.ftqq.com/${TOKEN}.send"

# Prepare message content
TITLE="QModem SMS: ($SMS_SENDER)"
DESP="**Time:** $SMS_TIME

**Sender:** $SMS_SENDER

**Content:** 
$SMS_CONTENT"

# URL encode function for GET method
url_encode() {
    echo "$1" | sed 's/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/-/%2D/g;s/\./%2E/g;s/\//%2F/g;s/:/%3A/g;s/;/%3B/g;s/</%3C/g;s/=/%3D/g;s/>/%3E/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\\/%5C/g;s/\]/%5D/g;s/\^/%5E/g;s/_/%5F/g;s/`/%60/g;s/{/%7B/g;s/|/%7C/g;s/}/%7D/g;s/~/%7E/g'
}

JSON_DATA=$(jq -n \
    --arg title "$TITLE" \
    --arg desp "$DESP" \
    --arg channel "$CHANNEL" \
    --arg noip "$NOIP" \
    --arg openid "$OPENID" \
    '{title:$title, desp:$desp}
     + (if $channel == "" or $channel == "null" then {} else {channel:$channel} end)
     + (if $noip == "" or $noip == "null" then {} else {noip:$noip} end)
     + (if $openid == "" or $openid == "null" then {} else {openid:$openid} end)') || exit 1

sms_forward_curl_request POST "$API_URL" "application/json;charset=utf-8" "$JSON_DATA" ""
exit $?
