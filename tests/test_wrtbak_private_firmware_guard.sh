#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$SCRIPT" ] || { echo "missing PrivateFirmwareGuard.sh"; exit 1; }
[ "$(git ls-files --stage -- "$SCRIPT" | awk '{print $1}')" = "100755" ] || {
	echo "PrivateFirmwareGuard.sh is not marked executable"
	exit 1
}

grep -q 'Scripts/PrivateFirmwareGuard.sh' "$WORKFLOW" || {
	echo "WRT-CORE.yml does not call the private firmware guard"
	exit 1
}

grep -q "if: env.WRT_PRIVATE_BUILD != 'true'" "$WORKFLOW" || {
	echo "Release Firmware step is not gated for private builds"
	exit 1
}

grep -q 'WRT_ARTIFACT_PRIVACY_SUFFIX' "$WORKFLOW" || {
	echo "artifact name does not include privacy suffix"
	exit 1
}

# Secrets must be scoped to the private overlay injection step, not exposed to
# checkout, third-party Actions, package feeds, or runtime download scripts.
GLOBAL_ENV="$(sed -n '/^env:/,/^jobs:/p' "$WORKFLOW")"
if printf '%s\n' "$GLOBAL_ENV" | grep -Fq 'secrets.'; then
	echo "workflow-level env exposes a secret to every build step"
	exit 1
fi
for secret_name in HEADSCALE_OPENWRT_AUTHKEY MULTICA_TOKEN MULTICA_SERVER_URL \
	MULTICA_APP_URL MULTICA_WORKSPACE_ID OPENWRT_DROPBEAR_AUTHORIZED_KEYS \
	WRTBAK_R2_ACCESS_KEY_ID WRTBAK_R2_SECRET_ACCESS_KEY; do
	grep -Fq "$secret_name: \${{secrets.$secret_name}}" "$WORKFLOW" || {
		echo "private overlay injection step is missing $secret_name"
		exit 1
	}
done
grep -Fq 'PrivateFirmwareGuard.sh "$GITHUB_WORKSPACE/wrt/files" > "$guard_env"' "$WORKFLOW" || {
	echo "private guard result is not validated before reaching GITHUB_ENV"
	exit 1
}
grep -Fq 'if [ "$credential_supplied" = true ]; then' "$WORKFLOW" || {
	echo "secret injection is not fail-closed when guard classification disagrees"
	exit 1
}
grep -Fq "if: inputs.WRT_SPLIT_DEVICE_ARTIFACTS == true && env.WRT_PRIVATE_BUILD != 'true'" "$WORKFLOW" || {
	echo "public split artifacts are not gated against secret-bearing firmware"
	exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

bash "$SCRIPT" "$WORK_DIR/empty" >"$WORK_DIR/public.env" 2>"$WORK_DIR/public.log"
grep -qx 'WRT_PRIVATE_BUILD=false' "$WORK_DIR/public.env" || {
	echo "empty overlay should not be private"
	exit 1
}

mkdir -p "$WORK_DIR/wrtbak/etc/config"
cat >"$WORK_DIR/wrtbak/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option proxy_url ''

config remote 's3'
	option access_key 'test-access'
	option secret_key 'test-secret'
EOT

bash "$SCRIPT" "$WORK_DIR/wrtbak" >"$WORK_DIR/wrtbak.env" 2>"$WORK_DIR/wrtbak.log"
grep -qx 'WRT_PRIVATE_BUILD=true' "$WORK_DIR/wrtbak.env" || {
	echo "wrtbak credentials should mark firmware private"
	exit 1
}
grep -q 'wrtbak-r2-secret-key' "$WORK_DIR/wrtbak.env" || {
	echo "wrtbak secret reason is missing"
	exit 1
}
if grep -q 'test-secret' "$WORK_DIR/wrtbak.log"; then
	echo "guard leaked wrtbak secret to logs"
	exit 1
fi

mkdir -p "$WORK_DIR/headscale/etc/tailscale"
printf '%s\n' 'hskey-auth-''testredacted' >"$WORK_DIR/headscale/etc/tailscale/headscale.authkey"
bash "$SCRIPT" "$WORK_DIR/headscale" >"$WORK_DIR/headscale.env" 2>/dev/null
grep -qx 'WRT_PRIVATE_BUILD=true' "$WORK_DIR/headscale.env" || {
	echo "headscale authkey should mark firmware private"
	exit 1
}
grep -q 'headscale-authkey' "$WORK_DIR/headscale.env" || {
	echo "headscale private reason is missing"
	exit 1
}

mkdir -p "$WORK_DIR/multica/etc/config"
cat >"$WORK_DIR/multica/etc/config/multica" <<'EOT'
config multica 'main'
	option enabled '1'
	option token 'mul_test_secret_pat'
EOT
bash "$SCRIPT" "$WORK_DIR/multica" >"$WORK_DIR/multica.env" 2>"$WORK_DIR/multica.log"
grep -qx 'WRT_PRIVATE_BUILD=true' "$WORK_DIR/multica.env" || {
	echo "multica token should mark firmware private"
	exit 1
}
grep -q 'multica-pat-token' "$WORK_DIR/multica.env" || {
	echo "multica private reason is missing"
	exit 1
}
if grep -q 'mul_test_secret_pat' "$WORK_DIR/multica.env" "$WORK_DIR/multica.log"; then
	echo "guard leaked the Multica PAT"
	exit 1
fi

echo "wrtbak private firmware guard test passed"
