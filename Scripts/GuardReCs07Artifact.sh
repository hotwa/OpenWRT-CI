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
		jdcloud_re-cs-02|jdcloud_re-ss-01)
			required_packages=(luci-app-openclaw luci-app-wrtbak)
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
	local upload="$1"
	(cd "$upload" && sha256sum -c SHA256SUMS >/dev/null) ||
		die "SHA256SUMS verification failed"
}

verify_upload() {
	local upload="$1" device="$2" file
	local -a files sysupgrades factories manifests configs
	validate_device "$device"
	check_flat_upload "$upload"
	mapfile -t files < <(find "$upload" -maxdepth 1 -type f -printf '%f\n' | sort)
	mapfile -t sysupgrades < <(find "$upload" -maxdepth 1 -type f -name "*${device}*sysupgrade.bin" -printf '%f\n')
	mapfile -t factories < <(find "$upload" -maxdepth 1 -type f -name "*${device}*factory*.bin" -printf '%f\n')
	mapfile -t manifests < <(find "$upload" -maxdepth 1 -type f -name '*.manifest' -printf '%f\n')
	mapfile -t configs < <(find "$upload" -maxdepth 1 -type f -name 'Config-*.txt' -printf '%f\n')
	[ "${#sysupgrades[@]}" -ge 1 ] || die "artifact must contain matching sysupgrade"
	[ "${#manifests[@]}" -eq 1 ] || die "artifact must contain one matching manifest"
	[ "${#configs[@]}" -eq 1 ] || die "artifact must contain one final config"
	[ -f "$upload/SHA256SUMS" ] || die "artifact is missing SHA256SUMS"
	check_manifest "$upload/${manifests[0]}"
	check_sha256sums "$upload"
}

stage_upload() {
	local source="$1" upload="$2" device="$3"
	local -a sysupgrades factories manifests configs
	validate_device "$device"
	check_flat_upload "$upload"
	mapfile -t sysupgrades < <(find "$source" -type f -name "*${device}*sysupgrade.bin" | sort)
	mapfile -t factories < <(find "$source" -type f -name "*${device}*factory*.bin" | sort)
	mapfile -t manifests < <(find "$source" -type f -name '*.manifest' | sort)
	[ "${#sysupgrades[@]}" -ge 1 ] || die "build output must contain matching sysupgrade for $device"
	[ "${#manifests[@]}" -ge 1 ] || die "build output must contain manifest"
	check_manifest "${manifests[0]}"
	mapfile -t configs < <(find "$upload" -maxdepth 1 -type f -name 'Config-*.txt')
	[ "${#configs[@]}" -eq 1 ] || die "upload staging must contain one final config"
	
	for img in "${sysupgrades[@]}" "${factories[@]}"; do
		[ -f "$img" ] && cp "$img" "$upload/"
	done
	cp "${manifests[0]}" "$upload/"
	(
		cd "$upload"
		sha256sum * >SHA256SUMS 2>/dev/null || true
		sed -i '/SHA256SUMS/d' SHA256SUMS
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
