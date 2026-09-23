#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
RELEASE="$ROOT_DIR/.github/workflows/WRT-RELEASE.yml"

for path in \
  "$ROOT_DIR/Scripts/TailscaleSysupgradeDeploy.sh" \
  "$ROOT_DIR/docs/headscale-ci-deploy-policy.md" \
  "$ROOT_DIR/tests/test_tailscale_sysupgrade_deploy.sh"; do
  [ ! -e "$path" ] || {
    echo "retired Tailnet CD repository path still exists: $path" >&2
    exit 1
  }
done

if rg -n \
  -g '*.yml' -g '*.yaml' -g '*.sh' -g '*.md' \
  'HEADSCALE_CD_AUTHKEY|WRT_CD_TAILSCALE|TAILSCALE_CD|TailscaleSysupgradeDeploy|tag:ci-deploy' \
  "$ROOT_DIR/.github/workflows" "$ROOT_DIR/Scripts" "$ROOT_DIR/docs" >/dev/null; then
  echo "workflow, scripts, or docs still expose retired Tailnet CD capability" >&2
  exit 1
fi

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

echo "CI workflow boundary guards passed"
