#!/bin/sh

. /usr/share/sms_forwarder/sms_forward_common.sh
sms_forward_read_input || exit 1

# Webhook SMS Forward Script
# Environment variables available:
# SMS_SENDER - sender phone number
# SMS_TIME - timestamp string
# SMS_CONTENT - SMS content

if [ -z "$API_CONFIG" ]; then
    echo "Error: API config not provided"
    exit 1
fi

# Extract configuration using jq or manual parsing
WEBHOOK_URL=$(printf '%s' "$API_CONFIG" | jq -r '.webhook_url' 2>/dev/null)
HEADERS=$(printf '%s' "$API_CONFIG" | jq -r '.headers' 2>/dev/null)
FORMAT=$(printf '%s' "$API_CONFIG" | jq -r '.format' 2>/dev/null)
REQUEST_METHOD=$(printf '%s' "$API_CONFIG" | jq -r '.request_method' 2>/dev/null)
# Fallback to manual parsing if jq fails
if [ -z "$WEBHOOK_URL" ] || [ "$WEBHOOK_URL" = "null" ]; then
    WEBHOOK_URL=$(echo "$API_CONFIG" | grep -o '"webhook_url":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$HEADERS" ] || [ "$HEADERS" = "null" ]; then
    HEADERS=$(echo "$API_CONFIG" | grep -o '"headers":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: Missing required webhook URL"
    exit 1
fi

# Prepare payload based on format
if [ -z "$FORMAT" ] || [ "$FORMAT" = "null" ];then
    payload="$SMS_SENDER/$SMS_CONTENT($SMS_TIME)"
else
    # Safe placeholder replacement using awk (handles all special characters)
    payload=$(printf '%s' "$FORMAT" | awk -v sender="$SMS_SENDER" -v time="$SMS_TIME" -v content="$SMS_CONTENT" '
    {
        gsub(/\{SENDER\}/, sender)
        gsub(/\{TIME\}/, time)
        gsub(/\{CONTENT\}/, content)
        print
    }')
    
    WEBHOOK_URL=$(printf '%s' "$WEBHOOK_URL" | awk -v sender="$SMS_SENDER" -v time="$SMS_TIME" -v content="$SMS_CONTENT" '
    {
        gsub(/\{SENDER\}/, sender)
        gsub(/\{TIME\}/, time)
        gsub(/\{CONTENT\}/, content)
        print
    }')
fi

# Prepare curl command
if [ -z "$REQUEST_METHOD" ] || [ "$REQUEST_METHOD" = "null" ]; then
    REQUEST_METHOD="GET"
fi


if [ "$REQUEST_METHOD" = "POST" ]; then
    sms_forward_curl_request POST "$WEBHOOK_URL" "application/json" "$payload" "$HEADERS"
else
    # URL-encode payload for GET request
    # Use jq for reliable URL encoding
    encoded_payload=$(printf '%s' "$payload" | jq -sRr @uri)
    full_url="${WEBHOOK_URL}/${encoded_payload}"
    
    sms_forward_curl_request GET "$full_url" "" "" "$HEADERS"
fi

exit $?
