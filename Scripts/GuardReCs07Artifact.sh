#!/usr/bin/env bash
set -euo pipefail

required_packages=()

die() {
	echo "JDCloud artifact guard: $*" >&2
	exit 1
}

validate_device() {
	case "$1" in
		jdcloud_re-cs-07)
			required_packages=(gre luci-proto-gre ip-full luci-app-wrtbak vm103-failover)
			;;
		jdcloud_re-cs-02)
			required_packages=(luci-app-wrtbak)
			;;
		jdcloud_re-ss-01)
			required_packages=(luci-app-wrtbak)
			;;
		*) die "unsupported expected device: $1" ;;
	esac
}

check_manifest() {
	local manifest="$1" package
	for package in "${required_packages[@]}"; do
		grep -Eq "^${package}[[:space:]]+-[[:space:]]+" "$manifest" ||
			die "manifest is missing required package: $package"
	done
}

check_defconfig() {
	local config="$1" device="$2" count package
	[ -f "$config" ] || die "missing defconfig: $config"
	validate_device "$device"
	count="$(grep -Ec '^CONFIG_TARGET_DEVICE_.*=y$' "$config" || true)"
	[ "$count" -eq 1 ] || die "defconfig must enable exactly one device"
	grep -qx "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_${device}=y" "$config" ||
		die "defconfig does not select $device"
	for package in "${required_packages[@]}"; do
		grep -qx "CONFIG_PACKAGE_${package}=y" "$config" ||
			die "defconfig is missing required package: $package"
	done
}

check_flat_upload() {
	local upload="$1"
	[ -d "$upload" ] || die "missing upload directory: $upload"
	[ -z "$(find "$upload" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] ||
		die "upload must contain only top-level regular files"
	[ -z "$(find "$upload" -mindepth 2 -print -quit)" ] ||
		die "upload must not contain nested paths"
}

check_sha256sums() {
	local upload="$1" line digest filename
	local expected listed sorted_listed
	expected="$(mktemp)"
	listed="$(mktemp)"
	sorted_listed="$(mktemp)"
	find "$upload" -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort >"$expected"

	while IFS= read -r line || [ -n "$line" ]; do
		digest="${line%%  *}"
		filename="${line#"$digest  "}"
		[ "$line" = "$digest  $filename" ] || die "SHA256SUMS contains a malformed line"
		printf '%s' "$digest" | grep -Eq '^[0-9a-fA-F]{64}$' ||
			die "SHA256SUMS contains an invalid digest"
		case "$filename" in
			''|-*|.|..|*/*|*\\*) die "SHA256SUMS contains an unsafe payload path" ;;
		esac
		grep -Fxq -- "$filename" "$listed" &&
			die "SHA256SUMS contains a duplicate payload: $filename"
		printf '%s\n' "$filename" >>"$listed"
	done <"$upload/SHA256SUMS"

	LC_ALL=C sort "$listed" >"$sorted_listed"
	cmp -s "$expected" "$sorted_listed" ||
		die "SHA256SUMS payload set does not match the artifact"
	rm -f "$expected" "$listed" "$sorted_listed"
	(cd "$upload" && sha256sum --check --strict -- SHA256SUMS >/dev/null) ||
		die "SHA256SUMS verification failed"
}

verify_upload() {
	local upload="$1" device="$2" payload_count expected_count
	local -a sysupgrades factories manifests configs metadata
	validate_device "$device"
	check_flat_upload "$upload"
	mapfile -t sysupgrades < <(find "$upload" -maxdepth 1 -type f -name "*${device}*sysupgrade.bin" -printf '%f\n')
	mapfile -t factories < <(find "$upload" -maxdepth 1 -type f -name "*${device}*factory*.bin" -printf '%f\n')
	mapfile -t manifests < <(find "$upload" -maxdepth 1 -type f -name '*.manifest' -printf '%f\n')
	mapfile -t configs < <(find "$upload" -maxdepth 1 -type f -name 'Config-*.txt' -printf '%f\n')
	mapfile -t metadata < <(find "$upload" -maxdepth 1 -type f -name 'metadata.json' -printf '%f\n')
	[ "${#sysupgrades[@]}" -ge 1 ] || die "artifact must contain matching sysupgrade"
	[ "${#factories[@]}" -ge 1 ] || die "artifact must contain matching factory"
	[ "${#manifests[@]}" -eq 1 ] || die "artifact must contain one matching manifest"
	[ "${#configs[@]}" -eq 1 ] || die "artifact must contain one final config"
	[ "${#metadata[@]}" -le 1 ] || die "artifact must contain at most one metadata file"
	[ -f "$upload/SHA256SUMS" ] || die "artifact is missing SHA256SUMS"
	payload_count="$(find "$upload" -maxdepth 1 -type f ! -name SHA256SUMS | wc -l)"
	expected_count=$((${#sysupgrades[@]} + ${#factories[@]} + 1 + 1 + ${#metadata[@]}))
	[ "$payload_count" -eq "$expected_count" ] ||
		die "artifact contains an unrecognized payload"
	check_manifest "$upload/${manifests[0]}"
	check_sha256sums "$upload"
}

stage_upload() {
	local source="$1" upload="$2" device="$3" image_dir payload_count
	local -a sysupgrades factories manifests configs
	validate_device "$device"
	check_flat_upload "$upload"
	mapfile -t sysupgrades < <(find "$source" -type f -name "*${device}*sysupgrade.bin" | sort)
	mapfile -t factories < <(find "$source" -type f -name "*${device}*factory*.bin" | sort)
	[ "${#sysupgrades[@]}" -ge 1 ] || die "build output must contain matching sysupgrade for $device"
	[ "${#factories[@]}" -ge 1 ] || die "build output must contain matching factory for $device"
	image_dir="$(dirname "${sysupgrades[0]}")"
	for img in "${sysupgrades[@]}" "${factories[@]}"; do
		[ "$(dirname "$img")" = "$image_dir" ] ||
			die "factory and sysupgrade images must share one target directory"
	done
	[ -z "$(find "$image_dir" -maxdepth 1 -type f -name '*.bin' ! -name "*${device}*" -print -quit)" ] ||
		die "build output contains firmware for an unexpected device"
	mapfile -t manifests < <(find "$image_dir" -maxdepth 1 -type f -name '*.manifest' | sort)
	[ "${#manifests[@]}" -eq 1 ] || die "target directory must contain exactly one manifest"
	check_manifest "${manifests[0]}"
	mapfile -t configs < <(find "$upload" -maxdepth 1 -type f -name 'Config-*.txt')
	[ "${#configs[@]}" -eq 1 ] || die "upload staging must contain one final config"
	payload_count="$(find "$upload" -maxdepth 1 -type f | wc -l)"
	[ "$payload_count" -eq 1 ] || die "upload staging contains an unexpected payload"

	for img in "${sysupgrades[@]}" "${factories[@]}"; do
		cp "$img" "$upload/"
	done
	cp "${manifests[0]}" "$upload/"
	(
		cd "$upload"
		find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' |
			LC_ALL=C sort | xargs sha256sum -- >SHA256SUMS
	)
	verify_upload "$upload" "$device"
}

case "${1:-}" in
	defconfig)
		[ "$#" -eq 3 ] || die "usage: $0 defconfig CONFIG DEVICE"
		check_defconfig "$2" "$3"
		;;
	stage)
		[ "$#" -eq 4 ] || die "usage: $0 stage SOURCE UPLOAD DEVICE"
		stage_upload "$2" "$3" "$4"
		;;
	verify)
		[ "$#" -eq 3 ] || die "usage: $0 verify UPLOAD DEVICE"
		verify_upload "$2" "$3"
		;;
	*)
		die "expected defconfig, stage, or verify"
		;;
esac
