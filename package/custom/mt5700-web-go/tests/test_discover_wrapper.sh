#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/files/usr/libexec/mt5700-web/discover"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

mkdir -p "$TEST_ROOT/usr/bin"
sed "s|exec /usr/bin/mt5700-web-go|exec $TEST_ROOT/usr/bin/mt5700-web-go|" \
	"$WRAPPER" > "$TEST_ROOT/discover"
chmod 0755 "$TEST_ROOT/discover"
cat > "$TEST_ROOT/usr/bin/mt5700-web-go" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod 0755 "$TEST_ROOT/usr/bin/mt5700-web-go"

assert_allowed() {
	actual="$($TEST_ROOT/discover "$@")"
	expected="$(printf '%s\n' -discover -modem-section "$1" -serial "$2")"
	[ "$actual" = "$expected" ] || {
		echo "FAIL: wrapper changed valid arguments" >&2
		exit 1
	}
}

assert_rejected() {
	if "$TEST_ROOT/discover" "$@" >/dev/null 2>&1; then
		echo "FAIL: wrapper accepted invalid arguments: $*" >&2
		exit 1
	fi
}

assert_allowed auto auto
assert_allowed modem_1 /dev/ttyUSB12
assert_allowed modem-2 /dev/ttyACM0
assert_allowed modem3 /dev/mhi_DUN
assert_allowed modem4 /dev/wwan0at1
assert_rejected auto
assert_rejected auto /tmp/ttyUSB0
assert_rejected auto /dev/ttyUSB0/../../etc/shadow
assert_rejected 'bad section' /dev/ttyUSB0
assert_rejected -listen /dev/ttyUSB0
assert_rejected "bad
section" /dev/ttyUSB0
assert_rejected auto "auto
-listen=0.0.0.0:9999"

echo 'MT5700 discovery wrapper tests passed'
