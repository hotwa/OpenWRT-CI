#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow-discovery.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT_DIR/files/etc/config/headscale_auto_enroll"
SCRIPT="$ROOT_DIR/files/usr/sbin/headscale-auto-enroll"
INIT="$ROOT_DIR/files/etc/init.d/headscale-auto-enroll"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/94-headscale-auto-enroll"
IDENTITY_MIGRATION="$ROOT_DIR/files/etc/uci-defaults/99-headscale-identity-migration"
HOTPLUG="$ROOT_DIR/files/etc/hotplug.d/iface/95-headscale-auto-enroll"
CI_INJECTOR="$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
DOC="$ROOT_DIR/docs/headscale-auto-enroll.md"
AGENTS="$ROOT_DIR/AGENTS.md"

[ -f "$CONFIG" ] || { echo "missing headscale auto-enroll config"; exit 1; }
[ -f "$SCRIPT" ] || { echo "missing headscale auto-enroll script"; exit 1; }
[ -f "$INIT" ] || { echo "missing headscale auto-enroll init script"; exit 1; }
[ -f "$DEFAULTS" ] || { echo "missing headscale auto-enroll uci-defaults"; exit 1; }
[ -f "$IDENTITY_MIGRATION" ] || { echo "missing Headscale identity migration"; exit 1; }
[ -f "$HOTPLUG" ] || { echo "missing headscale auto-enroll hotplug retry hook"; exit 1; }
[ -f "$CI_INJECTOR" ] || { echo "missing headscale auto-enroll CI injector"; exit 1; }
[ -f "$DOC" ] || { echo "missing headscale auto-enroll docs"; exit 1; }
[ -f "$AGENTS" ] || { echo "missing AGENTS.md"; exit 1; }

[ "$(git ls-files --stage -- "$SCRIPT" | awk '{print $1}')" = "100755" ] || {
  echo "headscale auto-enroll script is not marked executable"
  exit 1
}

[ "$(git ls-files --stage -- "$INIT" | awk '{print $1}')" = "100755" ] || {
  echo "headscale auto-enroll init script is not marked executable"
  exit 1
}

[ "$(git ls-files --stage -- "$CI_INJECTOR" | awk '{print $1}')" = "100755" ] || {
  echo "headscale auto-enroll CI injector is not marked executable"
  exit 1
}

tr -d '\r' < "$CONFIG" | grep -q "^	option enabled '0'$" || {
  echo "headscale auto-enroll must be disabled by default"
  exit 1
}

grep -q "option login_server 'https://headscale.jmsu.top'" "$CONFIG" || {
  echo "headscale login server default is missing"
  exit 1
}

grep -q "option auth_key_file '/etc/tailscale/headscale.authkey'" "$CONFIG" || {
  echo "headscale auth key file default is missing"
  exit 1
}

grep -q "option hostname_override ''" "$CONFIG" || {
	echo "headscale hostname override default is missing"
	exit 1
}

grep -q "option hostname_prefix ''" "$CONFIG" || {
	echo "headscale default hostname prefix must be empty"
	exit 1
}

grep -q "option hostname_mode 'legacy'" "$CONFIG" || {
	echo "headscale hostname mode default is missing"
	exit 1
}

grep -q "option hostname_model ''" "$CONFIG" || {
	echo "headscale hostname model default is missing"
	exit 1
}

grep -q "option accept_dns '0'" "$CONFIG" || {
  echo "headscale auto-enroll must not accept Tailscale DNS by default"
  exit 1
}

if grep -q "option accept_routes" "$CONFIG"; then
  echo "headscale auto-enroll must not own the Tailnet route-acceptance policy"
  exit 1
fi

grep -q "option restore_gate_file '/root/wrtbak/firstboot/gate.json'" "$CONFIG" || {
  echo "headscale auto-enroll does not declare the wrtbak recovery gate"
  exit 1
}

grep -q "option restore_gate_attempts '90'" "$CONFIG" || {
  echo "headscale auto-enroll does not bound the wrtbak gate wait"
  exit 1
}

grep -q -- '--accept-dns=' "$SCRIPT" || {
  echo "script does not pass accept-dns explicitly"
  exit 1
}

grep -Fq 'tailscale.settings.accept_routes' "$SCRIPT" || {
  echo "script does not read the canonical Tailscale route-acceptance policy"
  exit 1
}

grep -Fq 'accept_routes="$(tailnet_accept_routes)"' "$SCRIPT" || {
  echo "script does not apply the canonical Tailscale route-acceptance policy"
  exit 1
}

grep -q -- '--ssh=' "$SCRIPT" || {
  echo "script does not enable configurable Tailscale SSH"
  exit 1
}

grep -q 'apply_runtime_preferences' "$SCRIPT" || {
  echo "script does not re-apply runtime preferences to already-enrolled nodes"
  exit 1
}

grep -q 'wait_for_wrtbak_gate' "$SCRIPT" || {
  echo "script does not wait for the wrtbak firstboot decision"
  exit 1
}

grep -q 'reload_recovered_state' "$SCRIPT" || {
  echo "script does not reload a recovered Tailscale state"
  exit 1
}

grep -q 'acquire_enroll_lock' "$SCRIPT" || {
  echo "script does not serialize init and hotplug enrollment attempts"
  exit 1
}

grep -q 'reboot_pending' "$SCRIPT" || {
  echo "script does not keep enrollment closed while restore reboot is pending"
  exit 1
}

grep -q 'hostname_override="$(cfg hostname_override' "$SCRIPT" || {
  echo "script does not read the hostname override"
  exit 1
}

grep -q 'build_hostname "$hostname_mode" "$hostname_override" "$hostname_prefix" "$hostname_model" "$lan_ip"' "$SCRIPT" || {
	echo "script does not derive the hostname from the active LAN and model"
	exit 1
}

grep -q 'hostname_mode="$(cfg hostname_mode legacy)' "$SCRIPT" || {
	echo "script does not read the hostname mode"
	exit 1
}

grep -q 'hostname_model="$(cfg hostname_model' "$SCRIPT" || {
	echo "script does not read the hostname model"
	exit 1
}

grep -q 'lan-site)' "$SCRIPT" || {
	echo "script does not implement lan-site identity mode"
	exit 1
}

grep -q 'tailscale set' "$SCRIPT" || {
	echo "script does not use tailscale set for already-enrolled nodes"
	exit 1
}

grep -q -- '--hostname="$hostname"' "$SCRIPT" || {
	echo "script does not apply the migrated hostname to existing nodes"
	exit 1
}

grep -q 'TAILSCALE_STATE_READY_FILE' "$SCRIPT" || {
	echo "script does not hold enrollment until persistent Tailscale state is ready"
	exit 1
}

grep -q 'disable_tailscale_settings_reconciler' "$SCRIPT" || {
  echo "script does not disable the optional tailscale-settings reconciler"
  exit 1
}

grep -Fq '"$settings_init" disable' "$SCRIPT" || {
  echo "script does not keep the tailscale-settings reconciler opt-in"
  exit 1
}

grep -q 'tailscale already enrolled; runtime preferences applied' "$SCRIPT" || {
  echo "script does not log runtime preference application on already-enrolled nodes"
  exit 1
}

grep -q 'rm -f "$auth_key_file"' "$SCRIPT" || {
  echo "script does not remove the auth key file after successful enrollment"
  exit 1
}

grep -q '/etc/init.d/headscale-auto-enroll enable' "$DEFAULTS" || {
  echo "uci-defaults does not enable headscale auto-enroll service"
  exit 1
}

grep -q '\[ "\$ACTION" = "ifup" \]' "$HOTPLUG" || {
  echo "hotplug hook does not gate itself on interface ifup"
  exit 1
}

grep -q '/etc/init.d/headscale-auto-enroll start' "$HOTPLUG" || {
	echo "hotplug hook does not start headscale auto-enroll"
	exit 1
}

if grep -q '/etc/init.d/headscale-auto-enroll restart\|procd_set_param respawn' "$HOTPLUG" "$INIT"; then
	echo "one-shot Headscale enrollment must not be restarted or respawned by hotplug"
	exit 1
fi

grep -q 'HEADSCALE_OPENWRT_AUTHKEY' "$WORKFLOW" || {
  echo "workflow does not expose the optional Headscale OpenWrt auth key secret"
  exit 1
}

grep -q 'Scripts/HeadscaleAutoEnroll.sh' "$WORKFLOW" || {
  echo "workflow does not call the Headscale auto-enroll injector"
  exit 1
}

for caller_workflow in $(discover_device_workflows); do
  workflow_name="$(basename "$caller_workflow")"
  grep -q '^[[:space:]]*secrets:$' "$caller_workflow" || {
    echo "$workflow_name does not use an explicit WRT-CORE secret allowlist"
    exit 1
  }
  grep -q 'OPENWRT_DROPBEAR_AUTHORIZED_KEYS' "$caller_workflow" || {
    echo "$workflow_name does not pass OPENWRT_DROPBEAR_AUTHORIZED_KEYS to WRT-CORE"
    exit 1
  }
  if grep -q 'secrets: inherit\|HEADSCALE_CD_AUTHKEY' "$caller_workflow"; then
    echo "$workflow_name still grants an inherited or CD deployment secret"
    exit 1
  fi
done

grep -q 'auth key redacted' "$CI_INJECTOR" || {
  echo "CI injector does not redact the auth key in logs"
  exit 1
}

grep -q 'set_config_option accept_dns 0' "$CI_INJECTOR" || {
  echo "CI injector does not force accept_dns off"
  exit 1
}

if grep -q 'HEADSCALE_OPENWRT_ACCEPT_ROUTES\|set_config_option accept_routes' "$CI_INJECTOR"; then
  echo "CI injector must not override the canonical Tailscale route-acceptance policy"
  exit 1
fi

grep -q 'derive_headscale_model' "$CI_INJECTOR" || {
	echo "CI injector does not derive a stable Headscale model"
	exit 1
}

grep -q 'set_config_option hostname_mode lan-site' "$CI_INJECTOR" || {
	echo "CI injector does not enable LAN-derived hostname mode"
	exit 1
}

grep -q 'set_config_option hostname_model' "$CI_INJECTOR" || {
	echo "CI injector does not write hostname_model"
	exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/etc/config"
cp "$CONFIG" "$WORK_DIR/etc/config/headscale_auto_enroll"
TEST_AUTH_KEY="hskey-auth-""testredacted"
INJECT_LOG="$WORK_DIR/inject.log"
HEADSCALE_OPENWRT_AUTHKEY="$TEST_AUTH_KEY" \
WRT_NAME=DAE-WRT \
WRT_IP=192.168.12.1 \
bash "$CI_INJECTOR" "$WORK_DIR" >"$INJECT_LOG"

grep -q "option enabled '1'" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
  echo "CI injector does not enable auto-enroll when the secret is present"
  exit 1
}

grep -q "option accept_dns '0'" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
  echo "CI injector does not keep accept_dns disabled"
  exit 1
}

if grep -q "option accept_routes" "$WORK_DIR/etc/config/headscale_auto_enroll"; then
  echo "CI injector injected a duplicate route-acceptance setting"
  exit 1
fi

grep -q "option advertise_routes ''" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
	echo "CI injector must defer route selection to the live router LAN"
	exit 1
}

grep -q "option hostname_mode 'lan-site'" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
	echo "CI injector does not select lan-site hostname mode"
	exit 1
}

grep -q "option hostname_model 'daewrt'" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
	echo "CI injector does not derive hostname_model from WRT_NAME"
	exit 1
}

grep -q "option hostname_override ''" "$WORK_DIR/etc/config/headscale_auto_enroll" || {
	echo "CI injector must not bake WRT_IP into hostname_override"
	exit 1
}

[ "$(cat "$WORK_DIR/etc/tailscale/headscale.authkey")" = "$TEST_AUTH_KEY" ] || {
  echo "CI injector does not write the auth key file"
  exit 1
}

if grep -q "$TEST_AUTH_KEY" "$INJECT_LOG"; then
  echo "CI injector leaked the auth key to logs"
  exit 1
fi

SECOND_WORK_DIR="$(mktemp -d)"
mkdir -p "$SECOND_WORK_DIR/etc/config"
cp "$CONFIG" "$SECOND_WORK_DIR/etc/config/headscale_auto_enroll"
HEADSCALE_OPENWRT_AUTHKEY="$TEST_AUTH_KEY" \
HEADSCALE_OPENWRT_HOSTNAME="Lab Router 12" \
bash "$CI_INJECTOR" "$SECOND_WORK_DIR" >/dev/null

grep -q "option hostname_override 'lab-router-12'" "$SECOND_WORK_DIR/etc/config/headscale_auto_enroll" || {
  echo "CI injector does not honor and sanitize explicit HEADSCALE_OPENWRT_HOSTNAME"
  exit 1
}

grep -q "option hostname_mode 'explicit'" "$SECOND_WORK_DIR/etc/config/headscale_auto_enroll" || {
	echo "CI injector does not mark an explicit hostname as explicit"
	exit 1
}

grep -q "headscale_auto_enroll.main.hostname_mode=lan-site" "$IDENTITY_MIGRATION" || {
	echo "identity migration does not move legacy names to LAN-derived mode"
	exit 1
}

grep -q 'openwrt-re-' "$IDENTITY_MIGRATION" || {
	echo "identity migration does not recognize legacy openwrt names"
	exit 1
}

grep -q 'Do not commit an auth key' "$DOC" || {
  echo "docs do not warn against committed auth keys"
  exit 1
}

grep -q 'firmware artifact contains the enrollment key' "$DOC" || {
  echo "docs do not warn that private firmware artifacts contain the enrollment key"
  exit 1
}

grep -q 'Dropbear' "$AGENTS" || {
  echo "AGENTS.md does not document Dropbear as rescue path"
  exit 1
}

grep -q 'wrtbak recovery gate' "$DOC" || {
  echo "docs do not explain the wrtbak recovery gate"
  exit 1
}

# Check tracked repository content only. Ignored local browser/tool snapshots
# may contain redacted UI examples and are not part of the checkout artifact.
if git -C "$ROOT_DIR" grep -n -E 'hskey-auth-[A-Za-z0-9_-]+' -- . >/dev/null; then
  echo "repository contains a real-looking Headscale auth key"
  exit 1
fi

echo "headscale auto-enroll test passed"
