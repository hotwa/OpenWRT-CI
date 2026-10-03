#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/CPE-5G.yml"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
DOC="$ROOT_DIR/docs/cpe-5g-preset.md"

# Select one mapping and stop at the next sibling or ancestor key. Extra
# inputs/comments must not make a valid field fall outside a line-count window.
yaml_mapping_block() {
  local file="$1" indent="$2" key="$3"
  sed -n "/^${indent}${key}:\$/,/^ \{0,${#indent}\}[[:alnum:]_-]\{1,\}:/p" "$file" |
    sed "1b; /^ \{0,${#indent}\}[[:alnum:]_-]\{1,\}:/d"
}

grep -q '^CONFIG_PACKAGE_luci-app-lucky=y$' "$GENERAL" || {
  echo "Lucky is not enabled in the shared firmware package selection"
  exit 1
}

[ -f "$WORKFLOW" ] || {
  echo "missing CPE-5G workflow preset"
  exit 1
}

grep -q "name: CPE-5G" "$WORKFLOW" || {
  echo "CPE-5G workflow has the wrong name"
  exit 1
}

baseline_block="$(yaml_mapping_block "$WORKFLOW" '  ' baseline_a)"
cpe_block="$(yaml_mapping_block "$WORKFLOW" '  ' cpe_overlay_b)"
printf '%s\n' "$cpe_block" | grep -q 'WRT_IP: 192.168.13.1' || {
  echo "CPE-5G B control does not use 192.168.13.1"
  exit 1
}

grep -q 'WRT_CONFIG: IPQ60XX-706-NOWIFI' "$WORKFLOW" || {
  echo "CPE-5G A/B controls must build the IPQ60XX no-WiFi profile"
  exit 1
}

printf '%s\n' "$cpe_block" | grep -q 'CONFIG_PACKAGE_mwan3=y' || {
  echo "CPE-5G B does not install mwan3"
  exit 1
}
printf '%s\n' "$cpe_block" | grep -q 'CONFIG_PACKAGE_luci-app-mwan3=y' || {
  echo "CPE-5G B does not install luci-app-mwan3"
  exit 1
}
if printf '%s\n' "$baseline_block" | grep -q 'CONFIG_PACKAGE_.*mwan3=y'; then
  echo "CPE-5G A must not install mwan3"
  exit 1
fi
if grep -q '^CONFIG_PACKAGE_.*mwan3=y$' "$GENERAL"; then
  echo "shared firmware packages must not enable mwan3"
  exit 1
fi

grep -q 'WRT_PW:' "$WORKFLOW" || {
  echo "CPE-5G workflow must pass the required WRT_PW reusable input"
  exit 1
}

printf '%s\n' "$baseline_block" | grep -q 'WRT_LAN_TAILNET: false' || {
	echo "CPE-5G A isolation baseline must keep the unused gateway input disabled"
	exit 1
}

printf '%s\n' "$cpe_block" | grep -q 'WRT_LAN_TAILNET: true' || {
	echo "CPE-5G B must enable the private Mesh gateway"
	exit 1
}

for setting in 'WRT_EMMC_DATA_PROVISIONING: true' 'WRT_HEADSCALE_HOSTNAME: cpe-5g-s13' 'WRT_CPE_IPV6: true'; do
  printf '%s\n' "$cpe_block" | grep -Fq "$setting" || {
    echo "CPE B is missing $setting" >&2
    exit 1
  }
  if printf '%s\n' "$baseline_block" | grep -Fq "$setting"; then
    echo "CPE isolation A must not include B setting $setting" >&2
    exit 1
  fi
done

# Both controls receive private Samba credentials, independently of feature flags.
for control in baseline_a cpe_overlay_b; do
  yaml_mapping_block "$WORKFLOW" '  ' "$control" | grep -Fq 'WRT_ENCRYPT_ARTIFACT: true' || {
    echo "CPE control $control must encrypt its artifact" >&2
    exit 1
  }
done

grep -q 'WRT_CPE_5G: true' "$WORKFLOW" || {
  echo "CPE-5G workflow must enable the CPE network bootstrap"
  exit 1
}

! grep -q 'WRTBAK_FIRSTBOOT_AUTO_ENABLED:' "$WORKFLOW" || {
  echo "CPE-5G must not expose a wrtbak restore switch"
  exit 1
}

yaml_mapping_block "$CORE" '      ' WRT_CPE_5G | grep -q 'default: false' || {
  echo "reusable workflow must disable the CPE network bootstrap by default"
  exit 1
}

encrypt_input="$(yaml_mapping_block "$CORE" '      ' WRT_ENCRYPT_ARTIFACT)"
printf '%s\n' "$encrypt_input" | grep -q 'type: boolean' || {
  echo "reusable workflow artifact encryption input must be boolean"
  exit 1
}
printf '%s\n' "$encrypt_input" | grep -q 'default: false' || {
  echo "reusable workflow must disable artifact encryption by default"
  exit 1
}
yaml_mapping_block "$CORE" '' env | grep -Fq '  WRT_ENCRYPT_ARTIFACT: ${{inputs.WRT_ENCRYPT_ARTIFACT}}' || {
  echo "reusable workflow does not forward the artifact encryption input"
  exit 1
}

grep -q 'ConfigureCpe5G.sh.*WRT_CPE_5G' "$CORE" || {
  echo "reusable workflow does not invoke the CPE network bootstrap helper"
  exit 1
}

unknown_inputs=''
for input in $(sed -n '/^[[:space:]]*with:/,$s/^      \([A-Z][A-Z0-9_]*\):.*/\1/p' "$WORKFLOW"); do
  if ! grep -q "^      $input:\$" "$CORE"; then
    unknown_inputs="$unknown_inputs $input"
  fi
done
[ -z "$unknown_inputs" ] || {
  echo "CPE-5G workflow passes unknown WRT-CORE inputs:$unknown_inputs"
  exit 1
}

grep -q 'CI_NAME: CPE-706-B-6.18-MANUAL' "$WORKFLOW" || {
  echo "CPE-5G workflow must be pinned to the QCA-6.18 build track"
  exit 1
}

[ -f "$DOC" ] || {
  echo "missing CPE-5G preset documentation"
  exit 1
}

echo "CPE-5G preset test passed"
