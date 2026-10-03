#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/CPE-5G.yml"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
CONFIG="$ROOT_DIR/Config/IPQ60XX-706-NOWIFI.txt"
SHA='0bad892975fe49fd180f99b414a7f168bb694dd7'

# Select one mapping and stop at the next sibling or ancestor key. Extra
# inputs/comments must not make a valid field fall outside a line-count window.
yaml_mapping_block() {
  local file="$1" indent="$2" key="$3"
  sed -n "/^${indent}${key}:\$/,/^ \{0,${#indent}\}[[:alnum:]_-]\{1,\}:/p" "$file" |
    sed "1b; /^ \{0,${#indent}\}[[:alnum:]_-]\{1,\}:/d"
}

baseline_block="$(yaml_mapping_block "$WORKFLOW" '  ' baseline_a)"
cpe_block="$(yaml_mapping_block "$WORKFLOW" '  ' cpe_overlay_b)"

yaml_mapping_block "$WORKFLOW" '      ' BUILD_BASELINE_A | grep -Eq "default: ('false'|false)" || {
  echo 'CPE workflow must default BUILD_BASELINE_A to false'
  exit 1
}

printf '%s\n' "$baseline_block" | grep -q 'if:.*inputs.BUILD_BASELINE_A' || {
  echo 'A must run only when BUILD_BASELINE_A is explicitly enabled'
  exit 1
}

printf '%s\n' "$baseline_block" | grep -q 'WRT_CONFIG: IPQ60XX-706-NOWIFI' || {
  echo 'A must retain the known bootable NOWIFI isolation profile'
  exit 1
}
printf '%s\n' "$cpe_block" | grep -q 'WRT_CONFIG: IPQ60XX-706-WIFI' || {
  echo 'CPE B must select the single-device Wi-Fi candidate'
  exit 1
}

grep -q 'QCA-6.18-VIKINGYFY-IPQ60XX-NOWIFI_26.07.06-12.47.00' "$CONFIG" || {
  echo '7.06 NOWIFI config provenance is missing'
  exit 1
}

[ "$(grep -c '^CONFIG_TARGET_DEVICE_.*=y$' "$CONFIG")" -eq 1 ] &&
  grep -q '^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y$' "$CONFIG" || {
  echo 'controlled config must build only jdcloud_re-ss-01'
  exit 1
}

WIFI_CONFIG="$ROOT_DIR/Config/IPQ60XX-706-WIFI.txt"
[ -s "$WIFI_CONFIG" ] || { echo 'CPE WiFi config is missing'; exit 1; }
[ "$(grep -c '^CONFIG_TARGET_DEVICE_.*=y$' "$WIFI_CONFIG")" -eq 1 ] &&
  grep -Fxq 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y' "$WIFI_CONFIG" || {
  echo 'WiFi config must build only RE-SS-01'; exit 1;
}
for package in kmod-ath11k-ahb kmod-mac80211 kmod-cfg80211 \
  ath11k-firmware-ipq6018-ddwrt ipq-wifi-jdcloud_re-ss-01 \
  wifi-scripts wireless-regdb wpad-openssl hostapd-common iw iwinfo; do
  grep -Fxq "CONFIG_PACKAGE_${package}=y" "$WIFI_CONFIG" || {
    echo "WiFi config is missing $package"; exit 1;
  }
done
# Wireless capability must not change the controlled kernel/memory/NSS policy.
diff -u <(sed -n '/^CONFIG_TARGET_qualcommax=y$/,/^CONFIG_ATH11K_MEM_PROFILE_512M=y$/p' "$CONFIG") \
  <(sed -n '/^CONFIG_TARGET_qualcommax=y$/,/^CONFIG_ATH11K_MEM_PROFILE_512M=y$/p' "$WIFI_CONFIG")
for option in ATH11K_NSS_SUPPORT NSS_DRV_WIFI_EXT_VDEV_ENABLE; do
  grep -Fxq "# CONFIG_${option} is not set" "$WIFI_CONFIG" || {
    echo "WiFi NSS policy changed: $option"; exit 1;
  }
done
[[ IPQ60XX-706-WIFI != *NOWIFI* && IPQ60XX-706-WIFI != *WIFI-NO* ]] || exit 1

for job in baseline_a cpe_overlay_b; do
  grep -q "^  $job:" "$WORKFLOW" || {
    echo "missing controlled build job: $job"
    exit 1
  }
done

[ "$(grep -c "WRT_COMMIT: $SHA" "$WORKFLOW")" -eq 2 ] || {
  echo 'A and B must use the same immutable 7.06 source SHA'
  exit 1
}

printf '%s\n' "$baseline_block" | grep -q 'WRT_CPE_5G: false' || {
  echo 'A must not include the CPE network overlay'
  exit 1
}

printf '%s\n' "$cpe_block" | grep -q 'WRT_CPE_5G: true' || {
  echo 'B must include the CPE network overlay'
  exit 1
}

printf '%s\n' "$baseline_block" | grep -q 'WRT_FEATURE_OVERLAY: false' || {
  echo 'A must disable Lucky/Tailscale/Headscale/wrtbak feature overlays'
  exit 1
}

printf '%s\n' "$cpe_block" | grep -q 'WRT_FEATURE_OVERLAY: true' || {
  echo 'B must enable Lucky/Tailscale/Headscale/wrtbak feature overlays'
  exit 1
}

yaml_mapping_block "$CORE" '      ' WRT_FEATURE_OVERLAY | grep -q 'type: boolean' || {
  echo 'WRT-CORE must expose a boolean feature-overlay control'
  exit 1
}

for required in 'missing ${WRT_REQUIRED_DEVICE} factory image' 'missing ${WRT_REQUIRED_DEVICE} sysupgrade image' 'metadata.json' 'SHA256SUMS'; do
  grep -Fq "$required" "$CORE" || {
    echo "WRT-CORE is missing the CPE artifact gate: $required"
    exit 1
  }
done

echo 'CPE pinned NOWIFI isolation and Wi-Fi candidate build test passed'
