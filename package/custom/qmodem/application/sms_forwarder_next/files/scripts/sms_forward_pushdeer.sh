#!/bin/sh

. /usr/share/sms_forwarder/sms_forward_common.sh
sms_forward_read_input || exit 1

# PushDeer SMS Forward Script
# Environment variables available:
# SMS_SENDER - sender phone number
# SMS_TIME - timestamp string
# SMS_CONTENT - SMS content

if [ -z "$API_CONFIG" ]; then
    echo "Error: API config not provided"
    exit 1
fi

# Extract configuration using jq or manual parsing
PUSH_KEY=$(printf '%s' "$API_CONFIG" | jq -r '.pushkey' 2>/dev/null)
ENDPOINT=$(printf '%s' "$API_CONFIG" | jq -r '.endpoint' 2>/dev/null)

# Handle null values from jq
if [ "$PUSH_KEY" = "null" ] || [ -z "$PUSH_KEY" ]; then
    echo "Error: Missing required PushDeer push_key"
    exit 1
fi

# Handle null value for endpoint
if [ "$ENDPOINT" = "null" ]; then
    ENDPOINT=""
fi

# Set default endpoint if not provided
if [ -z "$ENDPOINT" ]; then
    ENDPOINT="https://api2.pushdeer.com"
fi

# Build API URL
API_URL="${ENDPOINT}/message/push"

# Prepare message content
TEXT="QModem SMS: ($SMS_SENDER)

Time: $SMS_TIME
Content: $SMS_CONTENT"

# URL encode function for GET method
url_encode() {
    echo "$1" | sed 's/ /%20/g; s/\n/%0A/g; s/&/%26/g; s/?/%3F/g; s/#/%23/g; s/=/%3D/g; s/+/%2B/g; s/@/%40/g; s/!/%21/g; s/\*/%2A/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/;/%3B/g; s/:/%3A/g; s/,/%2C/g; s/\$/%24/g; s/\[/%5B/g; s/\]/%5D/g; s/{/%7B/g; s/}/%7D/g; s/|/%7C/g; s/\\/%5C/g; s/\^/%5E/g; s/`/%60/g; s/"/%22/g; s/</%3C/g; s/>/%3E/g; s/~/%7E/g'
}

# URL encode the text
TEXT_ENCODED=$(url_encode "$TEXT")

FORM_DATA="pushkey=$PUSH_KEY&text=$TEXT_ENCODED&type=text"
sms_forward_curl_request POST "$API_URL" "application/x-www-form-urlencoded" "$FORM_DATA" ""
exit $?
