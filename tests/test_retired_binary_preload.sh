#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy_name="view""turbo"
legacy_binary="${legacy_name}core"
vendor_name="vt""fly"
rc_local="$ROOT_DIR/files/etc/rc.local"
migration="$ROOT_DIR/files/etc/uci-defaults/98-clean-legacy-startup"
workflow="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for removed_path in \
  "$ROOT_DIR/Scripts/fetch_${legacy_binary}.sh" \
  "$ROOT_DIR/files/usr/local/bin/${legacy_binary}"; do
  [ ! -e "$removed_path" ] || {
    echo "retired binary preload path remains: $removed_path" >&2
    exit 1
  }
done

[ -x "$migration" ] || {
	echo "missing executable legacy startup migration" >&2
	exit 1
}
grep -Fq 'cp -f ./files/etc/uci-defaults/98-clean-legacy-startup ./wrt/files/etc/uci-defaults/98-clean-legacy-startup' "$workflow" || {
	echo "WRT-CORE does not inject the legacy startup migration" >&2
	exit 1
}

legacy_binary="view""turbo""core"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fixture_rc_local="$fixture_dir/rc.local"
cat >"$fixture_rc_local" <<EOF
#!/bin/sh
keep-this-command
/usr/local/bin/$legacy_binary --start
exit 0
EOF
chmod 0751 "$fixture_rc_local"
LEGACY_RC_LOCAL_PATH="$fixture_rc_local" "$migration"
! grep -Fqi "$legacy_binary" "$fixture_rc_local" || {
	echo "legacy startup command was not removed" >&2
	exit 1
}
grep -Fxq 'keep-this-command' "$fixture_rc_local" || {
	echo "legacy startup migration removed an unrelated command" >&2
	exit 1
}
grep -Fxq 'exit 0' "$fixture_rc_local" || {
	echo "legacy startup migration removed the exit line" >&2
	exit 1
}
[ "$(stat -c '%a' "$fixture_rc_local")" = 751 ] || {
	echo "legacy startup migration did not preserve file mode" >&2
	exit 1
}
LEGACY_RC_LOCAL_PATH="$fixture_rc_local" "$migration"

[ -f "$rc_local" ] || {
  echo "missing rc.local overlay" >&2
  exit 1
}
for retained_line in \
  'rm -rf /.config' \
  'ln -sf /root/.config /.config' \
  'exit 0'; do
  tr -d '\r' < "$rc_local" | grep -Fxq "$retained_line" || {
    echo "rc.local lost retained startup behavior: $retained_line" >&2
    exit 1
  }
done

matches="$(rg -n -i --hidden \
  --glob '!.git/**' \
  -e "$legacy_name" \
  -e "$vendor_name" \
  "$ROOT_DIR" || true)"
[ -z "$matches" ] || {
  echo "retired binary preload references remain:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
}

echo "retired binary preload guard passed"
