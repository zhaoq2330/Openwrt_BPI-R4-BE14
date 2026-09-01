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

file_size() {
	wc -c < "$1" | tr -d '[:space:]'
}

require_file() {
	[ -f "$1" ] || die "missing artifact: $1"
	[ -s "$1" ] || die "empty artifact: $1"
}

check_max_size() {
	artifact=$1
	max_size=$2
	limit_name=$3
	artifact_size=$(file_size "$artifact")
	[ "$artifact_size" -le "$max_size" ] || \
		die "$(basename "$artifact") is ${artifact_size} bytes; ${limit_name} permits ${max_size}"
}

check_exact_size() {
	artifact=$1
	expected_size=$2
	artifact_size=$(file_size "$artifact")
	[ "$artifact_size" -eq "$expected_size" ] || \
		die "$(basename "$artifact") is ${artifact_size} bytes; expected exactly ${expected_size}"
}

compare_embedded() {
	artifact=$1
	offset_bytes=$2
	offset_name=$3
	label=$4
	artifact_size=$(file_size "$artifact")
	required_size=$(( offset_bytes + artifact_size ))
	[ "$sd_image_size" -ge "$required_size" ] || \
		die "SD image ends before ${label} at ${offset_name}"
	cmp -s -n "$artifact_size" "$artifact" "$sd_image" 0 "$offset_bytes" || \
		die "SD image ${label} differs from $(basename "$artifact") at ${offset_name}"
	note "embedded ${label}: ${offset_name} (${artifact_size} bytes)"
}

find_target_image() {
	image_name=$1
	found=
	for candidate in "$top_dir"/staging_dir/target-*/image/"$image_name"
	do
		[ -f "$candidate" ] || continue
		[ -z "$found" ] || die "multiple staging images found for $image_name"
		found=$candidate
	done
	[ -n "$found" ] || die "missing staging image: $image_name"
	printf '%s\n' "$found"
}

find_dumpimage() {
	if [ -n "${DUMPIMAGE:-}" ]; then
		[ -x "$DUMPIMAGE" ] || die "DUMPIMAGE is not executable: $DUMPIMAGE"
		printf '%s\n' "$DUMPIMAGE"
		return
	fi
	for candidate in \
		"$top_dir/staging_dir/host/bin/dumpimage" \
		"$top_dir/staging_dir/hostpkg/bin/dumpimage" \
		"$top_dir"/build_dir/host/u-boot-*/tools/dumpimage
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
	command -v dumpimage 2>/dev/null || die 'dumpimage not found (build tools first or set DUMPIMAGE)'
}

find_fdtoverlay() {
	if [ -n "${FDTOVERLAY:-}" ]; then
		[ -x "$FDTOVERLAY" ] || die "FDTOVERLAY is not executable: $FDTOVERLAY"
		printf '%s\n' "$FDTOVERLAY"
		return
	fi
	for candidate in \
		"$top_dir/staging_dir/host/bin/fdtoverlay" \
		"$top_dir/staging_dir/hostpkg/bin/fdtoverlay"
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
	command -v fdtoverlay 2>/dev/null || :
}

find_fwtool() {
	if [ -n "${FWTOOL:-}" ]; then
		[ -x "$FWTOOL" ] || die "FWTOOL is not executable: $FWTOOL"
		printf '%s\n' "$FWTOOL"
		return
	fi
	for candidate in \
		"$top_dir/staging_dir/host/bin/fwtool" \
		"$top_dir/staging_dir/hostpkg/bin/fwtool"
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
	command -v fwtool 2>/dev/null || die 'fwtool not found (build tools first or set FWTOOL)'
}

find_ubinize() {
	if [ -n "${UBINIZE:-}" ]; then
		[ -x "$UBINIZE" ] || die "UBINIZE is not executable: $UBINIZE"
		printf '%s\n' "$UBINIZE"
		return
	fi
	for candidate in \
		"$top_dir/staging_dir/host/bin/ubinize" \
		"$top_dir/staging_dir/hostpkg/bin/ubinize" \
		"$top_dir"/build_dir/host/mtd-utils-*/ubinize
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
	command -v ubinize 2>/dev/null || \
		die 'ubinize not found (build host mtd-utils first or set UBINIZE)'
}

find_fdtget() {
	if [ -n "${FDTGET:-}" ]; then
		[ -x "$FDTGET" ] || die "FDTGET is not executable: $FDTGET"
		printf '%s\n' "$FDTGET"
		return
	fi
	for candidate in \
		"$top_dir/staging_dir/host/bin/fdtget" \
		"$top_dir/staging_dir/hostpkg/bin/fdtget"
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return
		fi
	done
	command -v fdtget 2>/dev/null || die 'fdtget not found (build tools first or set FDTGET)'
}

normalize_appended_image() {
	source_image=$1
	normalized_image=$2
	cp "$source_image" "$normalized_image"
	# Keep this identical to include/image-commands.mk Build/append-image[-stage].
	"$fwtool_bin" -s /dev/null -t "$normalized_image" >/dev/null 2>&1 || :
	"$fwtool_bin" -i /dev/null -t "$normalized_image" >/dev/null 2>&1 || :
}

assert_fit_string() {
	fit_file=$1
	node_path=$2
	property_name=$3
	expected_value=$4
	actual_value=$("$fdtget_bin" -ts "$fit_file" "$node_path" "$property_name" 2>/dev/null) || \
		die "FIT property is missing: ${node_path}/${property_name}"
	[ "$actual_value" = "$expected_value" ] || \
		die "FIT ${node_path}/${property_name} is '${actual_value}', expected '${expected_value}'"
}

fit_payload_path() {
	fpp_fit_file=$1
	fpp_image_node=$2
	printf '%s/%s.payload.%s\n' \
		"$verify_tmp_dir" "$(basename "$fpp_fit_file")" "$fpp_image_node"
}

extract_fit_payload() {
	efp_fit_file=$1
	efp_image_node=$2
	efp_output_file=$3
	efp_nodes=$("$fdtget_bin" -l "$efp_fit_file" /images 2>/dev/null) || \
		die "FIT has no readable /images node: $(basename "$efp_fit_file")"
	efp_index=0
	efp_found=0
	for efp_node in $efp_nodes
	do
		if [ "$efp_node" = "$efp_image_node" ]; then
			efp_found=1
			break
		fi
		efp_index=$(( efp_index + 1 ))
	done
	[ "$efp_found" -eq 1 ] || \
		die "FIT payload node is missing: $efp_image_node"
	"$dumpimage_bin" -T flat_dt -p "$efp_index" -o "$efp_output_file" \
		"$efp_fit_file" >"$efp_output_file.extract.txt" 2>&1 || \
		die "cannot extract FIT payload $efp_image_node from $(basename "$efp_fit_file")"
	[ -s "$efp_output_file" ] || \
		die "extracted FIT payload is empty: $efp_image_node"
}

calculate_payload_hash() {
	cph_algorithm=$1
	cph_payload=$2
	case $cph_algorithm in
		crc32)
			require_command python3
			python3 - "$cph_payload" <<'PY'
import sys
import zlib

checksum = 0
with open(sys.argv[1], "rb") as payload:
    for chunk in iter(lambda: payload.read(1024 * 1024), b""):
        checksum = zlib.crc32(chunk, checksum)
print(f"{checksum & 0xffffffff:08x}")
PY
			;;
		sha1|sha256|sha384|sha512)
			cph_command=${cph_algorithm}sum
			require_command "$cph_command"
			"$cph_command" "$cph_payload" | {
				read -r cph_digest _
				printf '%s\n' "$cph_digest"
			}
			;;
		*)
			die "unsupported FIT payload hash algorithm: $cph_algorithm"
			;;
	esac
}

read_fit_hash_value() {
	rfh_fit_file=$1
	rfh_hash_path=$2
	rfh_bytes=$("$fdtget_bin" -tbx "$rfh_fit_file" \
		"$rfh_hash_path" value 2>/dev/null) || \
		die "FIT hash has no value: $rfh_hash_path"
	[ -n "$rfh_bytes" ] || die "FIT hash has an empty value: $rfh_hash_path"
	for rfh_byte in $rfh_bytes
	do
		case $rfh_byte in
			''|*[!0-9a-fA-F]*)
				die "FIT hash has a malformed value: $rfh_hash_path"
				;;
		esac
		[ "${#rfh_byte}" -le 2 ] || \
			die "FIT hash has a malformed byte: $rfh_hash_path"
		printf '%02x' "0x$rfh_byte"
	done
	printf '\n'
}

validate_fit_payload_hashes() {
	vph_fit_file=$1
	vph_nodes=$("$fdtget_bin" -l "$vph_fit_file" /images 2>/dev/null) || \
		die "FIT has no readable /images node: $(basename "$vph_fit_file")"
	[ -n "$vph_nodes" ] || die "FIT /images node is empty: $(basename "$vph_fit_file")"
	vph_payload_count=0
	for vph_image_node in $vph_nodes
	do
		vph_payload=$(fit_payload_path "$vph_fit_file" "$vph_image_node")
		extract_fit_payload "$vph_fit_file" "$vph_image_node" "$vph_payload"
		vph_hash_nodes=$("$fdtget_bin" -l "$vph_fit_file" \
			"/images/$vph_image_node" 2>/dev/null) || \
			die "cannot list hashes for FIT payload: $vph_image_node"
		vph_hash_count=0
		vph_strong_hash_count=0
		for vph_hash_node in $vph_hash_nodes
		do
			case $vph_hash_node in
				hash|hash-*|hash@*) ;;
				*) continue ;;
			esac
			vph_hash_path=/images/$vph_image_node/$vph_hash_node
			vph_algorithm=$("$fdtget_bin" -ts "$vph_fit_file" \
				"$vph_hash_path" algo 2>/dev/null) || \
				die "FIT hash has no algorithm: $vph_hash_path"
			# fdtget's hexadecimal integer output omits leading zeroes. Read the
			# property as bytes and pad every byte before comparing the digest.
			vph_expected=$(read_fit_hash_value "$vph_fit_file" "$vph_hash_path")
			vph_expected=$(printf '%s' "$vph_expected" | \
				tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
			vph_actual=$(calculate_payload_hash "$vph_algorithm" "$vph_payload")
			vph_actual=$(printf '%s' "$vph_actual" | \
				tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
			[ "$vph_actual" = "$vph_expected" ] || \
				die "FIT payload hash mismatch: $vph_image_node/$vph_hash_node"
			vph_hash_count=$(( vph_hash_count + 1 ))
			case $vph_algorithm in
				sha1|sha256|sha384|sha512)
					vph_strong_hash_count=$(( vph_strong_hash_count + 1 ))
					;;
			esac
		done
		[ "$vph_hash_count" -gt 0 ] || \
			die "FIT payload has no declared hashes: $vph_image_node"
		[ "$vph_strong_hash_count" -gt 0 ] || \
			die "FIT payload has no SHA integrity hash: $vph_image_node"
		vph_payload_count=$(( vph_payload_count + 1 ))
	done
	note "verified ${vph_payload_count} FIT payloads against all declared hashes"
}

validate_fit_overlays() {
	vfo_fit_file=$1
	if [ -z "$fdtoverlay_bin" ]; then
		note "fdtoverlay unavailable; skipped apply-time overlay validation"
		return
	fi
	vfo_base=$(fit_payload_path "$vfo_fit_file" fdt-1)
	[ -s "$vfo_base" ] || die "extracted FIT base FDT is missing: fdt-1"
	for vfo_overlay_name in \
		mt7988a-bananapi-bpi-r4-emmc \
		mt7988a-bananapi-bpi-r4-rtc \
		mt7988a-bananapi-bpi-r4-sd \
		mt7988a-bananapi-bpi-r4-wifi-be14
	do
		vfo_overlay=$(fit_payload_path "$vfo_fit_file" "fdt-$vfo_overlay_name")
		[ -s "$vfo_overlay" ] || \
			die "extracted FIT overlay is missing: $vfo_overlay_name"
		vfo_merged=$verify_tmp_dir/$(basename "$vfo_fit_file").merged.$vfo_overlay_name.dtb
		"$fdtoverlay_bin" -i "$vfo_base" -o "$vfo_merged" "$vfo_overlay" \
			>"$vfo_merged.fdtoverlay.txt" 2>&1 || \
			die "FIT overlay cannot be applied to the base FDT: $vfo_overlay_name"
		[ -s "$vfo_merged" ] || \
			die "fdtoverlay produced an empty FDT: $vfo_overlay_name"
	done
	vfo_wifi=$(fit_payload_path "$vfo_fit_file" \
		fdt-mt7988a-bananapi-bpi-r4-wifi-be14)
	for vfo_boot_media in sd emmc
	do
		vfo_media=$(fit_payload_path "$vfo_fit_file" \
			"fdt-mt7988a-bananapi-bpi-r4-$vfo_boot_media")
		vfo_combined=$verify_tmp_dir/$(basename "$vfo_fit_file").combined.$vfo_boot_media-be14.dtb
		"$fdtoverlay_bin" -i "$vfo_base" -o "$vfo_combined" \
			"$vfo_media" "$vfo_wifi" >"$vfo_combined.fdtoverlay.txt" 2>&1 || \
			die "FIT boot overlay stack cannot be applied: $vfo_boot_media + wifi-be14"
		[ -s "$vfo_combined" ] || \
			die "combined fdtoverlay produced an empty FDT: $vfo_boot_media + wifi-be14"
	done
	note 'applied all overlays individually plus SD+BE14 and eMMC+BE14 boot stacks'
}

validate_fit() {
	fit_file=$1
	fit_kind=$2
	required_payload=$3
	report_file="$verify_tmp_dir/$(basename "$fit_file").dumpimage.txt"
	"$dumpimage_bin" -l "$fit_file" > "$report_file" 2>&1 || \
		die "invalid ${fit_kind} FIT: $(basename "$fit_file")"
	for fit_name in \
		config-mt7988a-bananapi-bpi-r4 \
		mt7988a-bananapi-bpi-r4-emmc \
		mt7988a-bananapi-bpi-r4-rtc \
		mt7988a-bananapi-bpi-r4-sd \
		mt7988a-bananapi-bpi-r4-wifi-be14 \
		"$required_payload"
	do
		grep -F "$fit_name" "$report_file" >/dev/null || \
		die "${fit_kind} FIT is missing config/payload: ${fit_name}"
	done
	assert_fit_string "$fit_file" /configurations default config-mt7988a-bananapi-bpi-r4
	assert_fit_string "$fit_file" /configurations/config-mt7988a-bananapi-bpi-r4 kernel kernel-1
	assert_fit_string "$fit_file" /configurations/config-mt7988a-bananapi-bpi-r4 fdt fdt-1
	assert_fit_string "$fit_file" /images/kernel-1 type kernel
	assert_fit_string "$fit_file" /images/fdt-1 type flat_dt
	case $fit_kind in
		recovery)
			assert_fit_string "$fit_file" /configurations/config-mt7988a-bananapi-bpi-r4 ramdisk initrd-1
			assert_fit_string "$fit_file" /images/initrd-1 type ramdisk
			;;
		sysupgrade)
			assert_fit_string "$fit_file" /configurations/config-mt7988a-bananapi-bpi-r4 loadables rootfs-1
			assert_fit_string "$fit_file" /images/rootfs-1 type filesystem
			;;
	esac
	for overlay_name in \
		mt7988a-bananapi-bpi-r4-emmc \
		mt7988a-bananapi-bpi-r4-rtc \
		mt7988a-bananapi-bpi-r4-sd \
		mt7988a-bananapi-bpi-r4-wifi-be14
	do
		assert_fit_string "$fit_file" \
			"/configurations/$overlay_name" fdt "fdt-$overlay_name"
		assert_fit_string "$fit_file" "/images/fdt-$overlay_name" type flat_dt
	done
	validate_fit_payload_hashes "$fit_file"
	validate_fit_overlays "$fit_file"
	note "validated ${fit_kind} FIT configs, payloads and overlays"
}

ceil_divide() {
	cd_numerator=$1
	cd_denominator=$2
	printf '%s\n' $(( (cd_numerator + cd_denominator - 1) / cd_denominator ))
}

validate_snand_ubi_capacity() {
	vsu_recovery=$1
	vsu_production=$2
	vsu_recovery_size=$(file_size "$vsu_recovery")
	vsu_production_size=$(file_size "$vsu_production")
	vsu_raw_partition_bytes=$((126 * mib))
	vsu_raw_flash_bytes=$((128 * mib))
	vsu_peb_size=131072
	vsu_min_io_size=2048
	vsu_leb_size=$(( vsu_peb_size - 2 * vsu_min_io_size ))
	vsu_total_pebs=$(( vsu_raw_partition_bytes / vsu_peb_size ))
	vsu_flash_pebs=$(( vsu_raw_flash_bytes / vsu_peb_size ))

	# UBI calculates the bad-block limit from the whole 128 MiB flash, not
	# only the 126 MiB partition. Up to this configured limit, existing bad
	# PEBs reduce the reserve by the same amount and do not change capacity.
	vsu_bad_reserve_pebs=$(ceil_divide $(( vsu_flash_pebs * 20 )) 1024)
	vsu_wl_reserve_pebs=1
	vsu_atomic_reserve_pebs=1
	# U-Boot 2025.10 ubi_calc_fm_size() fits this 1008-PEB device in one
	# LEB and ubi_fastmap_init() keeps two copies.
	vsu_fastmap_reserve_pebs=2
	vsu_runtime_reserve_pebs=$((
		vsu_bad_reserve_pebs + vsu_wl_reserve_pebs +
		vsu_atomic_reserve_pebs + vsu_fastmap_reserve_pebs
	))
	# ubinize writes both layout-volume PEBs into the generated image.
	vsu_layout_pebs=2

	# Volumes created by the SD -> SPI-NAND installer. U-Boot rounds each
	# requested byte size up to a whole LEB, so aggregate bytes alone are not
	# sufficient. Keep one additional LEB for the later rootfs_data creation.
	vsu_env1_lebs=$(ceil_divide $((1 * mib)) "$vsu_leb_size")
	vsu_env2_lebs=$(ceil_divide $((1 * mib)) "$vsu_leb_size")
	vsu_fip_lebs=$(ceil_divide $((2 * mib)) "$vsu_leb_size")
	vsu_emmc_install_lebs=$(ceil_divide $((8 * mib)) "$vsu_leb_size")
	vsu_recovery_lebs=$(ceil_divide "$vsu_recovery_size" "$vsu_leb_size")
	vsu_production_lebs=$(ceil_divide "$vsu_production_size" "$vsu_leb_size")
	vsu_rootfs_data_min_lebs=1
	vsu_volume_pebs=$((
		vsu_env1_lebs + vsu_env2_lebs + vsu_fip_lebs +
		vsu_emmc_install_lebs + vsu_recovery_lebs +
		vsu_production_lebs + vsu_rootfs_data_min_lebs
	))
	vsu_expected_ubinize_pebs=$(( vsu_layout_pebs + vsu_volume_pebs ))
	vsu_required_pebs=$(( vsu_expected_ubinize_pebs + vsu_runtime_reserve_pebs ))
	vsu_free_pebs=$(( vsu_total_pebs - vsu_required_pebs ))
	[ "$vsu_required_pebs" -le "$vsu_total_pebs" ] || \
		die "SPI-NAND UBI needs ${vsu_required_pebs} PEBs, but the 126 MiB partition has only ${vsu_total_pebs} (includes metadata, fastmap, bad-block reserve and one rootfs_data LEB)"

	# Make ubinize materialize every reserved volume PEB, including otherwise
	# empty fixed-size volumes. Its output then independently verifies the
	# 126976-byte LEB geometry and per-volume rounding used above.
	vsu_env_image=$verify_tmp_dir/snand-ubi-env.bin
	vsu_fip_image=$verify_tmp_dir/snand-ubi-fip.bin
	vsu_emmc_install_image=$verify_tmp_dir/snand-ubi-emmc-install.bin
	vsu_rootfs_data_image=$verify_tmp_dir/snand-ubi-rootfs-data.bin
	truncate -s $((1 * mib)) "$vsu_env_image"
	truncate -s $((2 * mib)) "$vsu_fip_image"
	truncate -s $((8 * mib)) "$vsu_emmc_install_image"
	truncate -s "$vsu_leb_size" "$vsu_rootfs_data_image"
	vsu_ubi_image=$verify_tmp_dir/snand-capacity.ubi
	vsu_ubinize_log=$verify_tmp_dir/snand-capacity.ubinize.txt
	{
		printf '%s\n' \
			'[fip]' \
			'mode=ubi' \
			'vol_id=0' \
			'vol_type=static' \
			'vol_name=fip' \
			"vol_size=$((2 * mib))" \
			"image=$vsu_fip_image" \
			'[ubootenv]' \
			'mode=ubi' \
			'vol_id=1' \
			'vol_type=dynamic' \
			'vol_name=ubootenv' \
			"vol_size=$((1 * mib))" \
			"image=$vsu_env_image" \
			'[ubootenv2]' \
			'mode=ubi' \
			'vol_id=2' \
			'vol_type=dynamic' \
			'vol_name=ubootenv2' \
			"vol_size=$((1 * mib))" \
			"image=$vsu_env_image" \
			'[recovery]' \
			'mode=ubi' \
			'vol_id=3' \
			'vol_type=dynamic' \
			'vol_name=recovery' \
			"vol_size=$vsu_recovery_size" \
			"image=$vsu_recovery" \
			'[fit]' \
			'mode=ubi' \
			'vol_id=4' \
			'vol_type=dynamic' \
			'vol_name=fit' \
			"vol_size=$vsu_production_size" \
			"image=$vsu_production" \
			'[emmc_install]' \
			'mode=ubi' \
			'vol_id=5' \
			'vol_type=dynamic' \
			'vol_name=emmc_install' \
			"vol_size=$((8 * mib))" \
			"image=$vsu_emmc_install_image" \
			'[rootfs_data]' \
			'mode=ubi' \
			'vol_id=6' \
			'vol_type=dynamic' \
			'vol_name=rootfs_data' \
			"vol_size=$vsu_leb_size" \
			"image=$vsu_rootfs_data_image"
	} | "$ubinize_bin" -v -o "$vsu_ubi_image" \
		-p "$vsu_peb_size" -m "$vsu_min_io_size" \
		-s "$vsu_min_io_size" -O "$vsu_min_io_size" /dev/stdin \
		>"$vsu_ubinize_log" 2>&1 || \
		die "ubinize could not materialize the SPI-NAND volume layout; see $vsu_ubinize_log"
	awk -v expected="$vsu_leb_size" '
		$1 == "ubinize:" && $2 == "LEB" && $3 == "size:" && $4 == expected { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$vsu_ubinize_log" || die 'ubinize reported an unexpected SPI-NAND LEB size'
	awk '
		$1 == "ubinize:" && $2 == "data" && $3 == "offset:" && $4 == 4096 { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$vsu_ubinize_log" || die 'ubinize reported an unexpected SPI-NAND data offset'
	vsu_ubi_image_size=$(file_size "$vsu_ubi_image")
	[ $(( vsu_ubi_image_size % vsu_peb_size )) -eq 0 ] || \
		die 'ubinize output is not PEB-aligned'
	vsu_ubinize_pebs=$(( vsu_ubi_image_size / vsu_peb_size ))
	[ "$vsu_ubinize_pebs" -eq "$vsu_expected_ubinize_pebs" ] || \
		die "ubinize materialized ${vsu_ubinize_pebs} PEBs; formula expected ${vsu_expected_ubinize_pebs}"

	note "SPI-NAND geometry: ${vsu_total_pebs}x${vsu_peb_size}-byte PEB, ${vsu_leb_size}-byte LEB; ubinize verified ${vsu_ubinize_pebs} layout+volume PEBs"
	note "SPI-NAND UBI capacity: ${vsu_required_pebs}/${vsu_total_pebs} PEBs including ${vsu_runtime_reserve_pebs} runtime reserves (${vsu_free_pebs} extra PEBs for rootfs_data growth)"
}

sign_manifest_if_key_available() {
	smk_manifest=$1
	smk_private_key=$top_dir/private-key.pem
	smk_public_key=$top_dir/public-key.pem
	smk_output_signature=$output_dir/SHA256SUMS.sig
	smk_output_public_key=$output_dir/public-key.pem
	if [ ! -f "$smk_private_key" ]; then
		[ ! -e "$smk_output_signature" ] && [ ! -e "$smk_output_public_key" ] || \
			die 'stale signing outputs exist, but top-level private-key.pem is absent'
		note 'private-key.pem absent; SHA256SUMS remains unsigned'
		return
	fi
	[ -s "$smk_private_key" ] || die 'top-level private-key.pem is empty'
	require_command openssl
	smk_derived_public=$verify_tmp_dir/public-key.derived.pem
	smk_derived_der=$verify_tmp_dir/public-key.derived.der
	smk_export_public=$verify_tmp_dir/public-key.export.pem
	smk_export_der=$verify_tmp_dir/public-key.export.der
	smk_signature=$verify_tmp_dir/SHA256SUMS.sig
	openssl pkey -in "$smk_private_key" -pubout -out "$smk_derived_public" \
		</dev/null >/dev/null 2>&1 || die 'cannot derive public key from private-key.pem'
	openssl pkey -pubin -in "$smk_derived_public" -outform DER \
		-out "$smk_derived_der" >/dev/null 2>&1 || die 'cannot normalize derived public key'
	if [ -f "$smk_public_key" ]; then
		[ -s "$smk_public_key" ] || die 'top-level public-key.pem is empty'
		openssl pkey -pubin -in "$smk_public_key" -pubout \
			-out "$smk_export_public" >/dev/null 2>&1 || \
			die 'top-level public-key.pem is not a valid public key'
		openssl pkey -pubin -in "$smk_export_public" -outform DER \
			-out "$smk_export_der" >/dev/null 2>&1 || \
			die 'cannot normalize top-level public-key.pem'
		cmp -s "$smk_derived_der" "$smk_export_der" || \
			die 'public-key.pem does not match private-key.pem'
	else
		cp "$smk_derived_public" "$smk_export_public"
	fi
	openssl dgst -sha256 -sign "$smk_private_key" -out "$smk_signature" \
		"$smk_manifest" </dev/null >/dev/null 2>&1 || \
		die 'failed to sign SHA256SUMS with private-key.pem'
	openssl dgst -sha256 -verify "$smk_export_public" -signature "$smk_signature" \
		"$smk_manifest" >/dev/null 2>&1 || \
		die 'generated SHA256SUMS signature did not verify'
	cp "$smk_export_public" "$smk_output_public_key"
	cp "$smk_signature" "$smk_output_signature"
	openssl dgst -sha256 -verify "$smk_output_public_key" \
		-signature "$smk_output_signature" "$smk_manifest" >/dev/null 2>&1 || \
		die 'exported SHA256SUMS signature did not verify'
	note 'signed SHA256SUMS, exported public-key.pem and verified the signature'
}

assert_env_fragment() {
	aef_patch_file=$1
	aef_env_file=$2
	aef_fragment=$3
	awk -v marker="+++ b/defenvs/$aef_env_file" -v fragment="$aef_fragment" '
		$0 == marker { in_env = 1; next }
		in_env && /^--- / { in_env = 0 }
		in_env && index($0, fragment) > 0 { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$aef_patch_file" || \
		die "U-Boot installer assertion missing in $aef_env_file: $aef_fragment"
}

assert_uboot_installer_source() {
	aui_patch_file=$top_dir/package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch
	[ -r "$aui_patch_file" ] || die "missing BPI-R4 U-Boot patch: $aui_patch_file"
	for aui_sd_env in \
		bananapi_bpi-r4_sdmmc_env \
		bananapi_bpi-r4-poe_sdmmc_env
	do
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'sdmmc_read_snand_bl2=part start mmc 0 install part_addr && mmc read $loadaddr $part_addr 0x400'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'sdmmc_read_snand_fip=part start mmc 0 install part_addr && setexpr offset $part_addr + 0x800 && mmc read $loadaddr $offset 0x1000'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'sdmmc_read_emmc_install=part start mmc 0 install part_addr && setexpr offset $part_addr + 0x3800 && mmc read $loadaddr $offset 0x4000'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_create_env=ubi create ubootenv 0x100000 dynamic && ubi create ubootenv2 0x100000 dynamic'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_format=if ubi detach ; then true ; else true ; fi && mtd erase ubi && ubi part ubi'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_init_openwrt=run sdmmc_read_recovery && iminfo $loadaddr && run ubi_write_recovery && run sdmmc_read_production && iminfo $loadaddr && run ubi_write_production'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_write_fip=run ubi_remove_rootfs && if ubi check fip ; then ubi remove fip ; else true ; fi && ubi create fip 0x200000 static && ubi write $loadaddr fip 0x200000'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_write_emmc_install=if ubi check emmc_install ; then ubi remove emmc_install ; else true ; fi && ubi create emmc_install 0x800000 dynamic && ubi write $loadaddr emmc_install 0x800000'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_write_production=if ubi check fit ; then ubi remove fit ; else true ; fi && run ubi_remove_rootfs && ubi create fit $filesize dynamic && ubi write $loadaddr fit $filesize'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'ubi_write_recovery=if ubi check recovery ; then ubi remove recovery ; else true ; fi && run ubi_remove_rootfs && ubi create recovery $filesize dynamic && ubi write $loadaddr recovery $filesize'
		assert_env_fragment "$aui_patch_file" "$aui_sd_env" \
			'if run ubi_init ; then echo "NAND INSTALL SUCCESS" ; else echo "NAND INSTALL FAILED"'
	done
	for aui_snand_env in \
		bananapi_bpi-r4_snand_env \
		bananapi_bpi-r4-poe_snand_env
	do
		assert_env_fragment "$aui_patch_file" "$aui_snand_env" \
			'ubi_create_env=if ubi check ubootenv ; then true ; else ubi create ubootenv 0x100000 dynamic ; fi && if ubi check ubootenv2 ; then true ; else ubi create ubootenv2 0x100000 dynamic ; fi'
		assert_env_fragment "$aui_patch_file" "$aui_snand_env" \
			'emmc_init=mmc dev 0 && mmc bootbus 0 0 0 0 && run emmc_init_bl && run emmc_init_openwrt && env default bootcmd && saveenv && saveenv'
		assert_env_fragment "$aui_patch_file" "$aui_snand_env" \
			'emmc_init_openwrt=run ubi_read_recovery && iminfo $loadaddr && run emmc_write_recovery && run ubi_read_production && iminfo $loadaddr && run emmc_write_production'
		assert_env_fragment "$aui_patch_file" "$aui_snand_env" \
			'emmc_write_bl2=if mmc partconf 0 1 1 1 && mmc erase 0x0 0x400 && mmc write $fileaddr 0x0 0x400 ; then mmc partconf 0 1 1 0 ; else mmc partconf 0 1 1 0 ; false ; fi'
		assert_env_fragment "$aui_patch_file" "$aui_snand_env" \
			'if run emmc_init ; then echo "eMMC INSTALL SUCCESS" ; else echo "eMMC INSTALL FAILED"'
	done
	for aui_emmc_env in \
		bananapi_bpi-r4_emmc_env \
		bananapi_bpi-r4-poe_emmc_env
	do
		assert_env_fragment "$aui_patch_file" "$aui_emmc_env" \
			'emmc_write_bl2=if mmc partconf 0 1 1 1 && mmc erase 0x0 0x400 && mmc write $fileaddr 0x0 0x400 ; then mmc partconf 0 1 1 0 ; else mmc partconf 0 1 1 0 ; false ; fi'
	done
	note 'validated fail-fast non-PoE and PoE SD -> SPI-NAND -> eMMC U-Boot installer source'
}

assert_layout_source() {
	layout_file="$top_dir/target/linux/mediatek/image/filogic.mk"
	[ -r "$layout_file" ] || die "missing image layout source: $layout_file"
	for layout_fragment in \
		'pad-to 17k | mt7988-bl2 sdmmc-comb' \
		'pad-to 6656k | mt7988-bl31-uboot $$(DEVICE_NAME)-sdmmc' \
		'pad-to 12M | append-image-stage initramfs-recovery.itb' \
		'pad-to 44M | mt7988-bl2 spim-nand-ubi-comb' \
		'pad-to 45M | mt7988-bl31-uboot $$(DEVICE_NAME)-snand' \
		'pad-to 51M | mt7988-bl2 emmc-comb' \
		'pad-to 52M | mt7988-bl31-uboot $$(DEVICE_NAME)-emmc' \
		'pad-to 56M | mt798x-gpt emmc' \
		'pad-to 64M | append-image squashfs-sysupgrade.itb'
	do
		grep -F "$layout_fragment" "$layout_file" >/dev/null || \
			die "verification layout is stale; not found in filogic.mk: $layout_fragment"
	done
	snand_dts_patch="$top_dir/target/linux/mediatek/patches-6.12/189-arm64-dts-mediatek-mt7988a-complete-bpi-r4.patch"
	[ -r "$snand_dts_patch" ] || die "missing BPI-R4 SPI-NAND layout source: $snand_dts_patch"
	grep -F 'reg = <0x200000 0x7e00000>;' "$snand_dts_patch" >/dev/null || \
		die 'BPI-R4 SPI-NAND UBI partition is no longer 126 MiB'
	ubi_guard_source="$top_dir/include/image-commands.mk"
	grep -F 'UBI_NAND_SIZE_LIMIT = $(IMAGE_SIZE) - ($(NAND_SIZE)*20/1024 + 4*$(BLOCKSIZE))' \
		"$ubi_guard_source" >/dev/null || \
		die 'OpenWrt UBI reserve formula changed; update SPI-NAND capacity validation'
	assert_uboot_installer_source
}

usage() {
	printf 'Usage: %s [bin/targets/mediatek/filogic]\n' "$(basename "$0")" >&2
	exit 2
}

[ "$#" -le 1 ] || usage

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$top_dir"

[ -r build-meta/versions.env ] || die 'missing build-meta/versions.env'
# shellcheck disable=SC1091
. ./build-meta/versions.env

case ${1:-bin/targets/mediatek/filogic} in
	/*) output_dir=${1:-bin/targets/mediatek/filogic} ;;
	*) output_dir="$top_dir/${1:-bin/targets/mediatek/filogic}" ;;
esac
[ -d "$output_dir" ] || die "artifact directory not found: $output_dir"

require_command cmp
require_command cp
require_command gzip
require_command sha256sum
require_command tr
require_command truncate
require_command wc
cmp --help 2>&1 | grep -q -- '--bytes' || die 'GNU-compatible cmp with -n/--bytes is required'

prefix=$IMAGE_PREFIX
emmc_gpt_name=${prefix}-emmc-gpt.bin
emmc_preloader_name=${prefix}-emmc-preloader.bin
emmc_fip_name=${prefix}-emmc-bl31-uboot.fip
sd_gzip_name=${prefix}-sdcard.img.gz
snand_preloader_name=${prefix}-snand-preloader.bin
snand_fip_name=${prefix}-snand-bl31-uboot.fip
recovery_name=${prefix}-initramfs-recovery.itb
sysupgrade_name=${prefix}-squashfs-sysupgrade.itb

emmc_gpt=$output_dir/$emmc_gpt_name
emmc_preloader=$output_dir/$emmc_preloader_name
emmc_fip=$output_dir/$emmc_fip_name
sd_gzip=$output_dir/$sd_gzip_name
snand_preloader=$output_dir/$snand_preloader_name
snand_fip=$output_dir/$snand_fip_name
recovery=$output_dir/$recovery_name
sysupgrade=$output_dir/$sysupgrade_name

for artifact in \
	"$emmc_gpt" \
	"$emmc_preloader" \
	"$emmc_fip" \
	"$sd_gzip" \
	"$snand_preloader" \
	"$snand_fip" \
	"$recovery" \
	"$sysupgrade"
do
	require_file "$artifact"
done
note 'found all 8 required BPI-R4 artifacts'

assert_layout_source
mib=1048576
sd_preloader=$(find_target_image mt7988-sdmmc-comb-bl2.img)
sd_fip=$(find_target_image mt7988_bananapi_bpi-r4-sdmmc-u-boot.fip)
require_file "$sd_preloader"
require_file "$sd_fip"

gzip -t "$sd_gzip" || die "gzip integrity check failed: $sd_gzip_name"
verify_tmp_dir=$(mktemp -d)
trap 'rm -rf "$verify_tmp_dir"' EXIT HUP INT TERM
sd_image=$verify_tmp_dir/${prefix}-sdcard.img
gzip -dc "$sd_gzip" > "$sd_image"
sd_image_size=$(file_size "$sd_image")
note "decompressed SD image (${sd_image_size} bytes)"

fwtool_bin=$(find_fwtool)
ubinize_bin=$(find_ubinize)
embedded_recovery=$verify_tmp_dir/$recovery_name
embedded_sysupgrade=$verify_tmp_dir/$sysupgrade_name
normalize_appended_image "$recovery" "$embedded_recovery"
normalize_appended_image "$sysupgrade" "$embedded_sysupgrade"

# The broad SD gaps are not always the usable limits. These tighter limits
# match the U-Boot installer read/write windows in bananapi_bpi-r4_*_env.
check_max_size "$sd_preloader" $((4079 * 1024)) 'SD BL2 partition (17-4096 KiB)'
check_max_size "$sd_fip" $((4 * mib)) 'SD FIP partition (4 MiB)'
check_max_size "$embedded_recovery" $((32 * mib)) '12-44 MiB recovery slot'
check_max_size "$snand_preloader" 524288 'SNAND installer BL2 window (512 KiB)'
check_max_size "$snand_fip" $((2 * mib)) 'SNAND UBI FIP volume (2 MiB)'
check_max_size "$emmc_preloader" 524288 'eMMC installer BL2 window (512 KiB)'
check_max_size "$emmc_fip" $((4 * mib)) 'eMMC installer FIP window (4 MiB)'
check_exact_size "$emmc_gpt" 17408
check_max_size "$embedded_sysupgrade" $((ROOTFS_PARTSIZE_MIB * mib)) \
	"production slot (${ROOTFS_PARTSIZE_MIB} MiB)"
embedded_recovery_size=$(file_size "$embedded_recovery")
embedded_sysupgrade_size=$(file_size "$embedded_sysupgrade")
validate_snand_ubi_capacity "$embedded_recovery" "$embedded_sysupgrade"
expected_sd_image_size=$((64 * mib + embedded_sysupgrade_size))
[ "$sd_image_size" -eq "$expected_sd_image_size" ] || \
	die "SD image is ${sd_image_size} bytes; expected ${expected_sd_image_size} from layout"
note 'all artifacts fit their installer windows and the SD image length is exact'

compare_embedded "$sd_preloader" $((17 * 1024)) '17 KiB' 'SD preloader'
compare_embedded "$sd_fip" $((6656 * 1024)) '6656 KiB' 'SD FIP'
compare_embedded "$embedded_recovery" $((12 * mib)) '12 MiB' 'recovery FIT'
compare_embedded "$snand_preloader" $((44 * mib)) '44 MiB' 'SPI-NAND preloader'
compare_embedded "$snand_fip" $((45 * mib)) '45 MiB' 'SPI-NAND FIP'
compare_embedded "$emmc_preloader" $((51 * mib)) '51 MiB' 'eMMC preloader'
compare_embedded "$emmc_fip" $((52 * mib)) '52 MiB' 'eMMC FIP'
compare_embedded "$emmc_gpt" $((56 * mib)) '56 MiB' 'eMMC GPT'
compare_embedded "$embedded_sysupgrade" $((64 * mib)) '64 MiB' \
	'sysupgrade FIT (fwtool metadata stripped)'

dumpimage_bin=$(find_dumpimage)
fdtget_bin=$(find_fdtget)
fdtoverlay_bin=$(find_fdtoverlay)
validate_fit "$recovery" recovery initrd-1
validate_fit "$sysupgrade" sysupgrade rootfs-1

sum_tmp=$verify_tmp_dir/SHA256SUMS
(
	cd "$output_dir"
	sha256sum \
		"$emmc_gpt_name" \
		"$emmc_preloader_name" \
		"$emmc_fip_name" \
		"$recovery_name" \
		"$sd_gzip_name" \
		"$snand_preloader_name" \
		"$snand_fip_name" \
		"$sysupgrade_name"
) > "$sum_tmp"
mv "$sum_tmp" "$output_dir/SHA256SUMS"
(
	cd "$output_dir"
	sha256sum -c SHA256SUMS >/dev/null
)
note "wrote $output_dir/SHA256SUMS"
sign_manifest_if_key_available "$output_dir/SHA256SUMS"
note 'artifact verification passed'
