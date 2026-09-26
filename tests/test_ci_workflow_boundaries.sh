#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
RELEASE="$ROOT_DIR/.github/workflows/WRT-RELEASE.yml"
CD_WORKFLOW="$ROOT_DIR/.github/workflows/FIRMWARE-FLEET-CD.yml"
CD_SCRIPT="$ROOT_DIR/Scripts/FirmwareFleetDeploy.sh"
FLEET="$ROOT_DIR/Config/firmware-fleet.json"

[ -f "$CD_WORKFLOW" ] || { echo "firmware CD workflow is missing" >&2; exit 1; }
[ -x "$CD_SCRIPT" ] || { echo "firmware CD guard script is missing or not executable" >&2; exit 1; }
[ -f "$FLEET" ] || { echo "firmware fleet inventory is missing" >&2; exit 1; }

if grep -R -n -E 'secrets:[[:space:]]+inherit' "$ROOT_DIR/.github/workflows"; then
  echo "WRT-CORE callers must use explicit secret allowlists" >&2
  exit 1
fi

allowed_secrets='HEADSCALE_OPENWRT_AUTHKEY HEADSCALE_CI_AUTHKEY HEADSCALE_URL MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_APP_URL MULTICA_WORKSPACE_ID OPENWRT_DROPBEAR_AUTHORIZED_KEYS OPENWRT_WAN_PPPOE_USERNAME OPENWRT_WAN_PPPOE_PASSWORD NIKKI_SUBSCRIPTION_URL COMMANDCODE_API_KEY CLIPROXYAPI_API_KEY CLIPROXYAPI_BASE_URL SAMBA_DEFAULT_PASSWORD'
for secret in $allowed_secrets; do
  grep -Fq "      $secret:" "$CORE" || {
    echo "WRT-CORE no longer declares expected build secret: $secret" >&2
    exit 1
  }
done

for workflow in "$ROOT_DIR"/.github/workflows/*.yml; do
  grep -Fq 'uses: ./.github/workflows/WRT-CORE.yml' "$workflow" || continue
  grep -Eq '^[[:space:]]*secrets:$' "$workflow" || {
    echo "$(basename "$workflow") has no explicit reusable-workflow secret mapping" >&2
    exit 1
  }
  grep -Fq 'OPENWRT_DROPBEAR_AUTHORIZED_KEYS:' "$workflow" || {
    echo "$(basename "$workflow") must preserve the Dropbear build secret mapping" >&2
    exit 1
  }
  while IFS= read -r mapped_secret; do
    case " $allowed_secrets " in
      *" $mapped_secret "*) ;;
      *)
        echo "$(basename "$workflow") maps an undeclared or forbidden secret: $mapped_secret" >&2
        exit 1
        ;;
    esac
  done < <(sed -n -E 's/^[[:space:]]{6}([A-Z][A-Z0-9_]*):[[:space:]]*\$\{\{[[:space:]]*secrets\..*$/\1/p' "$workflow")

  # GitHub validates nested reusable-workflow permissions before a conditional
  # WRT-CORE release job can be skipped. The actual WRT-CORE build job below
  # must still reduce this ceiling to read-only.
  grep -Fq 'contents: write' "$workflow" || {
    echo "$(basename "$workflow") cannot satisfy the nested release permission ceiling" >&2
    exit 1
  }
done

grep -A12 '^  build:' "$CORE" | grep -Fq 'contents: read' || {
  echo "WRT-CORE build job must have contents: read" >&2
  exit 1
}
grep -A12 '^  build:' "$CORE" | grep -Fq 'actions: read' || {
  echo "WRT-CORE build job must have actions: read" >&2
  exit 1
}
grep -A10 '^  release:' "$CORE" | grep -Fq 'contents: write' || {
  echo "WRT-CORE release job must be the sole elevated boundary" >&2
  exit 1
}
grep -A14 '^  release:' "$CORE" | grep -Fq 'uses: ./.github/workflows/WRT-RELEASE.yml' || {
  echo "WRT-CORE release boundary does not delegate to WRT-RELEASE" >&2
  exit 1
}

grep -Fq 'contents: write' "$RELEASE"
grep -Fq 'actions: read' "$RELEASE"
if grep -Eq 'id-token:|packages:|attestations:|security-events:' "$RELEASE"; then
  echo "WRT-RELEASE requests permissions outside its release boundary" >&2
  exit 1
fi

grep -Fq 'workflow_dispatch:' "$CD_WORKFLOW" || {
  echo "firmware CD must require a manual dispatch" >&2
  exit 1
}
grep -Fq 'default: false' "$CD_WORKFLOW" || {
  echo "firmware CD deploy input must default to false" >&2
  exit 1
}
grep -Fq 'environment: firmware-cd' "$CD_WORKFLOW" || {
  echo "firmware CD must use the protected firmware-cd environment" >&2
  exit 1
}
preflight_block="$(sed -n '/^  preflight:/,/^  deploy:/p' "$CD_WORKFLOW")"
grep -Fxq '    environment: firmware-cd' <<<"$preflight_block" || {
  echo "firmware CD preflight must use the environment that stores its Tailnet and SSH secrets" >&2
  exit 1
}
grep -Fq 'HEADSCALE_CI_AUTHKEY' "$CD_WORKFLOW" || {
  echo "firmware CD must use the unified CI Tailnet credential" >&2
  exit 1
}
if [ "$(grep -Fc 'secrets.HEADSCALE_CI_AUTHKEY' "$CD_WORKFLOW")" -ne 2 ]; then
  echo "both protected CD jobs must use the unified CI Tailnet credential" >&2
  exit 1
fi
if grep -Fq 'HEADSCALE_CD_AUTHKEY' "$CD_WORKFLOW"; then
  echo "firmware CD must not depend on a second Headscale auth-key secret" >&2
  exit 1
fi
grep -Fq 'FIRMWARE_CD_SSH_PRIVATE_KEY' "$CD_WORKFLOW" || {
  echo "firmware CD must require a dedicated SSH key" >&2
  exit 1
}
grep -Fq 'FIRMWARE_CD_KNOWN_HOSTS' "$CD_WORKFLOW" || {
  echo "firmware CD must pin router SSH host keys" >&2
  exit 1
}
if grep -Eq 'HEADSCALE_CD_AUTHKEY|FIRMWARE_CD_SSH_PRIVATE_KEY|FIRMWARE_CD_KNOWN_HOSTS' "$CORE"; then
  echo "build boundary must not receive deployment secrets" >&2
  exit 1
fi

grep -Fq 'sysupgrade -T' "$CD_SCRIPT" || {
  echo "firmware CD must validate a sysupgrade image before flashing" >&2
  exit 1
}
grep -Fq 'sysupgrade -c' "$CD_SCRIPT" || {
  echo "firmware CD must retain configuration during sysupgrade" >&2
  exit 1
}
grep -Fq "requirements='data,wan,tailscale,magicdns,nikki'" "$CD_SCRIPT" &&
  grep -Fq '/usr/sbin/openwrt-ci-health --require __HEALTH_REQUIREMENTS__' "$CD_SCRIPT" || {
  echo "firmware CD must construct the required pre/post upgrade health check" >&2
  exit 1
}
upgrade_body="$(sed -n '/^upgrade_record() {/,/^}/p' "$CD_SCRIPT")"
if [ "$(grep -Fc 'preflight_record "$record" "$ssh_config"' <<<"$upgrade_body")" -ne 2 ]; then
  echo "firmware CD must run health preflight before and after sysupgrade" >&2
  exit 1
fi
grep -Fq 'StrictHostKeyChecking yes' "$CD_WORKFLOW" || {
  echo "firmware CD must reject unpinned SSH host keys" >&2
  exit 1
}

echo "CI workflow boundary guards passed"
