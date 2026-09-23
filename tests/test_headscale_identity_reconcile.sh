#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/ReconcileHeadscaleFleetIdentity.sh"
INVENTORY="$ROOT_DIR/Config/firmware-fleet.json"

[ -x "$SCRIPT" ] || { echo "Headscale identity reconciliation script is not executable" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/nodes.json" <<'EOF'
[
  {"id": 7, "givenName": "openwrt-re-cs-02-11", "approvedRoutes": ["192.168.11.0/24"]},
  {"id": 8, "givenName": "cs07-10", "approvedRoutes": ["192.168.10.0/24"]},
  {"id": 9, "givenName": "ss01-12", "approvedRoutes": ["192.168.12.0/24"]}
]
EOF
cat > "$WORK_DIR/bin/headscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2 $3" = 'nodes list --output' ] && [ "$4" = json ]; then
  cat "$HEADSCALE_TEST_NODES"
  exit 0
fi
if [ "$1 $2" = 'nodes rename' ]; then
  printf '%s\n' "$*" >> "$HEADSCALE_TEST_RENAMES"
  exit 0
fi
exit 2
EOF
chmod 755 "$WORK_DIR/bin/headscale"

PATH="$WORK_DIR/bin:$PATH" \
HEADSCALE_TEST_NODES="$WORK_DIR/nodes.json" \
HEADSCALE_TEST_RENAMES="$WORK_DIR/renames" \
bash "$SCRIPT" --inventory "$INVENTORY" > "$WORK_DIR/dry-run"

grep -q 'rename planned: node 7 openwrt-re-cs-02-11 -> cs02-11' "$WORK_DIR/dry-run" || {
	echo "dry run did not select the retained Headscale node" >&2
	exit 1
}
[ ! -e "$WORK_DIR/renames" ] || { echo "dry run mutated Headscale" >&2; exit 1; }

PATH="$WORK_DIR/bin:$PATH" \
HEADSCALE_TEST_NODES="$WORK_DIR/nodes.json" \
HEADSCALE_TEST_RENAMES="$WORK_DIR/renames" \
bash "$SCRIPT" --inventory "$INVENTORY" --apply >/dev/null

grep -Fxq 'nodes rename -i 7 cs02-11' "$WORK_DIR/renames" || {
	echo "apply did not rename exactly the intended node" >&2
	exit 1
}

echo "Headscale identity reconciliation test passed"
