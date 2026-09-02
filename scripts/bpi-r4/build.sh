#!/bin/sh
set -eu

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '==> %s\n' "$*"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

check_positive_integer() {
	case $2 in
		''|*[!0-9]*|0) die "$1 must be a positive integer (got: $2)" ;;
	esac
}

check_boolean() {
	case $2 in
		0|1) ;;
		*) die "$1 must be 0 or 1 (got: $2)" ;;
	esac
}

check_path_component() {
	case $2 in
		''|.|..|*[!A-Za-z0-9_.-]*)
			die "$1 is not a safe path component (got: $2)"
			;;
	esac
}

check_feed_pin() {
	feed_name=$1
	feed_commit=$2
	if ! grep -Eq "^src-git([[:space:]]+--subdir=[^[:space:]]+)?[[:space:]]+${feed_name}[[:space:]]+[^[:space:]]+\\^${feed_commit}$" feeds.conf.default; then
		die "feeds.conf.default does not pin ${feed_name} to ${feed_commit}"
	fi
}

check_file_pin() {
	pin_file=$1
	pin_text=$2
	[ -r "$pin_file" ] || die "source metadata file is missing: $pin_file"
	grep -F "$pin_text" "$pin_file" >/dev/null || \
		die "source pin is stale in ${pin_file}: ${pin_text}"
}

check_git_checkout() {
	checkout_name=$1
	checkout_path=$2
	expected_commit=$3

	[ -d "$checkout_path" ] || die "${checkout_name} checkout is missing: ${checkout_path}"
	git -C "$checkout_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
		die "${checkout_name} is not a Git checkout: ${checkout_path}"
	actual_commit=$(git -C "$checkout_path" rev-parse HEAD) || \
		die "cannot resolve ${checkout_name} HEAD"
	[ "$actual_commit" = "$expected_commit" ] || \
		die "${checkout_name} is at ${actual_commit}, expected ${expected_commit}"
	checkout_status=$(git -C "$checkout_path" status --porcelain=v1 --untracked-files=all) || \
		die "cannot inspect ${checkout_name} worktree"
	[ -z "$checkout_status" ] || \
		die "${checkout_name} checkout is not clean: ${checkout_path}"
}

is_first_parent_ancestor() {
	ifa_expected=$1
	ifa_current=$2
	while [ -n "$ifa_current" ]; do
		[ "$ifa_current" = "$ifa_expected" ] && return 0
		ifa_current=$(git cat-file -p "$ifa_current" 2>/dev/null | \
			sed -n 's/^parent //p' | head -n1) || return 1
	done
	return 1
}

check_pinned_feed_checkouts() {
	check_git_checkout 'packages feed' feeds/packages "$PACKAGES_FEED_COMMIT"
	check_git_checkout 'LuCI feed' feeds/luci "$LUCI_FEED_COMMIT"
	check_git_checkout 'routing feed' feeds/routing "$ROUTING_FEED_COMMIT"
	check_git_checkout 'telephony feed' feeds/telephony "$TELEPHONY_FEED_COMMIT"
	check_git_checkout 'video feed' feeds/video "$VIDEO_FEED_COMMIT"
	check_git_checkout 'MediaTek feed' feeds/mtk_openwrt_feed "$MTK_FEED_COMMIT"
}

check_single_filogic_device() {
	enabled_devices=$(sed -n \
		-e 's/^CONFIG_TARGET_mediatek_filogic_DEVICE_\(.*\)=y$/\1/p' \
		-e 's/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_\(.*\)=y$/\1/p' \
		.config)
	enabled_count=$(printf '%s\n' "$enabled_devices" | sed '/^$/d' | wc -l | tr -d '[:space:]')
	[ "$enabled_count" = 1 ] || \
		die "defconfig enabled ${enabled_count} Filogic devices; expected only ${BUILD_PROFILE}"
	[ "$enabled_devices" = "$BUILD_PROFILE" ] || \
		die "defconfig selected Filogic device ${enabled_devices}; expected ${BUILD_PROFILE}"
}

run_make() {
	[ "${SOURCE_DATE_EPOCH:-}" = "$OPENWRT_SOURCE_DATE_EPOCH" ] || \
		die 'SOURCE_DATE_EPOCH changed after source-pin validation'
	make SOURCE_DATE_EPOCH="$OPENWRT_SOURCE_DATE_EPOCH" "$@"
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$top_dir"

[ ! -e feeds.conf ] && [ ! -L feeds.conf ] || \
	die 'local feeds.conf overrides are forbidden; use the pinned feeds.conf.default'

[ -r build-meta/versions.env ] || die 'missing build-meta/versions.env'
# shellcheck disable=SC1091
. ./build-meta/versions.env

require_command git
require_command flock
require_command grep
require_command awk
require_command make
require_command mkdir
require_command rm
require_command sed
require_command tr
require_command wc

mkdir -p tmp
exec 9>tmp/.bpi-r4-build.lock
flock -n 9 || die "another build is already using this source tree: ${top_dir}"

jobs=${JOBS:-}
if [ -z "$jobs" ]; then
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n')
fi
check_positive_integer JOBS "$jobs"
check_positive_integer OPENWRT_SOURCE_DATE_EPOCH "$OPENWRT_SOURCE_DATE_EPOCH"

allow_dirty_project=${ALLOW_DIRTY_PROJECT:-0}
check_boolean ALLOW_DIRTY_PROJECT "$allow_dirty_project"

check_path_component BUILD_TARGET "$BUILD_TARGET"
check_path_component BUILD_SUBTARGET "$BUILD_SUBTARGET"
check_path_component BUILD_PROFILE "$BUILD_PROFILE"

build_verbose=${BUILD_VERBOSE:-s}

git_top_dir=$(git rev-parse --show-toplevel 2>/dev/null) || die 'project is not a Git checkout'
[ "$git_top_dir" = "$top_dir" ] || die "project Git root is ${git_top_dir}, expected ${top_dir}"
git cat-file -e "${OPENWRT_COMMIT}^{commit}" 2>/dev/null || \
	die "pinned OpenWrt commit is unavailable: ${OPENWRT_COMMIT}"
# Walk only as far as the pinned base. This also supports the documented
# source bundle, which deliberately omits history older than that boundary.
is_first_parent_ancestor "$OPENWRT_COMMIT" HEAD || \
	die "current history is not based on pinned OpenWrt commit ${OPENWRT_COMMIT}"
base_commit_epoch=$(git cat-file -p "$OPENWRT_COMMIT" | \
	awk '/^committer / { print $(NF - 1); exit }')
[ "$base_commit_epoch" = "$OPENWRT_SOURCE_DATE_EPOCH" ] || \
	die "SOURCE_DATE_EPOCH does not match the pinned OpenWrt commit"

check_feed_pin packages "$PACKAGES_FEED_COMMIT"
check_feed_pin luci "$LUCI_FEED_COMMIT"
check_feed_pin routing "$ROUTING_FEED_COMMIT"
check_feed_pin telephony "$TELEPHONY_FEED_COMMIT"
check_feed_pin video "$VIDEO_FEED_COMMIT"
check_feed_pin mtk_openwrt_feed "$MTK_FEED_COMMIT"

check_file_pin target/linux/generic/kernel-6.12 \
	"LINUX_KERNEL_HASH-${LINUX_VERSION} = ${LINUX_SOURCE_SHA256}"
check_file_pin package/boot/uboot-mediatek/Makefile "PKG_VERSION:=${UBOOT_VERSION}"
check_file_pin package/boot/uboot-mediatek/Makefile "PKG_HASH:=${UBOOT_SOURCE_SHA256}"
check_file_pin package/boot/arm-trusted-firmware-mediatek/Makefile \
	"PKG_SOURCE_VERSION:=${ATF_MEDIATEK_COMMIT}"
check_file_pin package/boot/arm-trusted-firmware-mediatek/Makefile \
	"PKG_MIRROR_HASH:=${ATF_MEDIATEK_MIRROR_SHA256}"
check_file_pin package/kernel/mac80211/Makefile "PKG_VERSION:=${BACKPORTS_VERSION}"
check_file_pin package/kernel/mac80211/Makefile "PKG_HASH:=${BACKPORTS_SOURCE_SHA256}"
check_file_pin package/kernel/mt76/Makefile "PKG_SOURCE_VERSION:=${MT76_COMMIT}"
check_file_pin package/kernel/mt76/Makefile "PKG_MIRROR_HASH:=${MT76_MIRROR_SHA256}"
check_file_pin package/network/services/hostapd/Makefile \
	"PKG_SOURCE_VERSION:=${HOSTAPD_COMMIT}"
check_file_pin package/network/services/hostapd/Makefile \
	"PKG_MIRROR_HASH:=${HOSTAPD_MIRROR_SHA256}"
check_file_pin package/custom/bandix/Makefile "RUST_BANDIX_VERSION:=${BANDIX_VERSION}"
check_file_pin package/custom/bandix/Makefile \
	"PKG_HASH:=${BANDIX_BINARY_SHA256_AARCH64}"
check_file_pin package/custom/luci-app-bandix/Makefile \
	"PKG_VERSION:=${BANDIX_LUCI_VERSION}"
check_file_pin rules.mk 'TAR_OPTIONS:=--no-same-owner -xf -'
check_file_pin scripts/feeds "git clone --depth 1 --no-checkout"

if grep -R -I -E 'chmod[[:space:]]+47[0-9]{2}' package/custom/luci-app-openclash; then
	die 'OpenClash source still enables a setuid core executable'
fi
if grep -R -I -- '--allow-untrusted' package/custom/luci-app-openclash; then
	die 'OpenClash source still permits untrusted APK installation'
fi

[ -r "$BUILD_CONFIG" ] || die "missing build config: $BUILD_CONFIG"
grep -qx 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y' "$BUILD_CONFIG" || \
	die 'build config does not select the BPI-R4 non-PoE profile'
if grep -qx 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4-poe=y' "$BUILD_CONFIG"; then
	die 'build config unexpectedly selects the BPI-R4 PoE profile'
fi
grep -qx "CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE_MIB}" "$BUILD_CONFIG" || \
	die "build config rootfs size is not ${ROOTFS_PARTSIZE_MIB} MiB"

project_status=$(git status --porcelain=v1 --untracked-files=all --ignore-submodules=none) || \
	die 'cannot inspect project worktree'
project_commit=$(git rev-parse HEAD) || die 'cannot resolve project HEAD'
if [ -n "$project_status" ]; then
	[ "$allow_dirty_project" = 1 ] || \
		die 'project worktree is not clean; commit the source boundary or use ALLOW_DIRTY_PROJECT=1 for a developer-only build'
	printf '%s\n' \
		'warning: ALLOW_DIRTY_PROJECT=1: HEAD plus local changes are build inputs; output is not a release-reproducible build' >&2
else
	note "Project source boundary: clean HEAD ${project_commit}"
fi

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=$OPENWRT_SOURCE_DATE_EPOCH
FORCE_UNSAFE_CONFIGURE=${FORCE_UNSAFE_CONFIGURE:-1}
export FORCE_UNSAFE_CONFIGURE

note "OpenWrt ${OPENWRT_RELEASE}, base ${OPENWRT_COMMIT}"
note 'Updating and installing pinned feeds'
./scripts/feeds update -a
./scripts/feeds install -a
note 'Verifying pinned feed commits and clean feed worktrees'
check_pinned_feed_checkouts

note "Applying ${BUILD_CONFIG}"
cp "$BUILD_CONFIG" .config
run_make defconfig
check_single_filogic_device
for required_package in \
	bandix luci-app-bandix kmod-mt7996-firmware kmod-mt7996e \
	mt7988-wo-firmware kmod-nft-offload mtkhnat_util
do
	grep -qx "CONFIG_PACKAGE_${required_package}=y" .config || \
		die "required offload/Bandix package is not selected: ${required_package}"
done
check_file_pin package/kernel/mt76/Makefile 'MODPARAMS.mt7996e:=wed_enable=1'
check_file_pin package/custom/bpi-r4-be14-defaults/files/99-bpi-r4-be14-defaults \
	"set firewall.@defaults[0].flow_offloading_hw='1'"

note "Downloading sources with ${jobs} job(s)"
run_make -j"$jobs" download V="$build_verbose"

output_dir="bin/targets/${BUILD_TARGET}/${BUILD_SUBTARGET}"
for output_parent in bin bin/targets "bin/targets/${BUILD_TARGET}"; do
	[ ! -L "$output_parent" ] || \
		die "refusing to clean output through symlinked path component: ${output_parent}"
done
note "Removing stale target output: ${output_dir}"
rm -rf -- "$output_dir"

note "Building ${BUILD_TARGET}/${BUILD_SUBTARGET}/${BUILD_PROFILE} with ${jobs} job(s)"
run_make -j"$jobs" V="$build_verbose"

image_manifest=$(find "$output_dir" -maxdepth 1 -type f -name "${IMAGE_PREFIX}*.manifest" | head -n1)
[ -n "$image_manifest" ] || die 'built image package manifest is missing'
for required_package in bandix luci-app-bandix bpi-r4-be14-defaults kmod-mt7996e mt7988-wo-firmware
do
	grep -Eq "^${required_package}([[:space:]]|-)" "$image_manifest" || \
		die "built image manifest is missing package: ${required_package}"
done
note 'Verified Bandix, defaults, MT7996 and WED firmware in image manifest'

note 'Verifying BPI-R4 artifacts'
"$script_dir/verify-artifacts.sh" "$output_dir"
