#!/bin/sh
set -eu

collector=${1:-$(dirname "$0")/../files/bandix-ppe-collector}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/debug/mtk_ppe" "$test_dir/runtime" "$test_dir/bin"

cat >"$test_dir/bin/ip" <<'EOF'
#!/bin/sh
echo '192.168.66.10 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE'
EOF
chmod +x "$test_dir/bin/ip"

write_bind() {
	cat >"$test_dir/debug/mtk_ppe/bind" <<EOF
00042 state=bind type=ipv4_hnapt ppe=0 orig=192.168.66.10:50000->1.1.1.1:443 new=203.0.113.2:50000->1.1.1.1:443 packets=10 bytes=$1
00043 state=bind type=ipv4_hnapt ppe=0 orig=1.1.1.1:443->203.0.113.2:50000 new=1.1.1.1:443->192.168.66.10:50000 packets=20 bytes=$2
EOF
}

run_collector() {
	BANDIX_PPE_FORCE_OFFLOAD=1 \
	BANDIX_PPE_INTERVAL=10 \
	BANDIX_PPE_RUNTIME_DIR="$test_dir/runtime" \
	BANDIX_PPE_DEBUG_ROOT="$test_dir/debug" \
	BANDIX_PPE_IP_COMMAND="$test_dir/bin/ip" \
		"$collector" --once
}

write_bind 1000 2000
run_collector
set -- $(cat "$test_dir/runtime/device-totals")
[ "$1" = aa:bb:cc:dd:ee:ff ]
[ "$3" = 2000 ]
[ "$4" = 1000 ]

write_bind 1600 3200
run_collector
set -- $(cat "$test_dir/runtime/device-totals")
[ "$3" = 3200 ]
[ "$4" = 1600 ]
set -- $(cat "$test_dir/runtime/device-sample")
[ "$3" = 1200 ]
[ "$4" = 600 ]
[ "$5" = 120 ]
[ "$6" = 60 ]

# A reused/reset FOE counter contributes only its new value, never a negative
# delta or the previous flow's byte count.
write_bind 50 80
run_collector
set -- $(cat "$test_dir/runtime/device-totals")
[ "$3" = 3280 ]
[ "$4" = 1650 ]

echo 'PPE collector simulation: PASS'
