#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/docs/agent-runtime-version-policy.md"
AGENTS="$ROOT_DIR/AGENTS.md"
README="$ROOT_DIR/README.md"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
CORE_BUILDER="$ROOT_DIR/Scripts/build_hermes_core.sh"
UV_STORAGE="$ROOT_DIR/files/etc/init.d/uv-storage"
PROVISIONER="$ROOT_DIR/files/usr/sbin/hermes-runtime-provision"

fail() { echo "agent runtime docs policy: $*" >&2; exit 1; }
for path in "$POLICY" "$AGENTS" "$README" "$WORKFLOW" "$CORE_BUILDER" "$UV_STORAGE" "$PROVISIONER"; do
  [ -f "$path" ] || fail "missing $path"
done

# The release schedule and signing wording must match the actual workflow.
grep -Eq "cron: ['\"]?0 \* \* \* \*['\"]?" "$WORKFLOW" || fail "workflow is no longer hourly"
for term in '每小时 UTC 第 0 分钟' '已签名的不可变 generation' '签名 index 与' '发布后才把验证过的应用层 pin 提交到 `main`'; do
  grep -Fq "$term" "$POLICY" || fail "policy omits release contract: $term"
done

# /data/node is intentionally an agent-runtime-owned compatibility link, not a
# mutable package prefix. Keep the wording tied to the service implementation.
grep -Fq '/data/node is a compatibility symlink managed by agent-runtime' "$UV_STORAGE" ||
  fail "uv-storage no longer documents the managed compatibility link"
for term in '/data/node` 只是 Runtime Manager 发布的**兼容链接**' '不是可写的 npm/pnpm 全局安装位置' 'agent-runtime upgrade'; do
  grep -Fq "$term" "$POLICY" || fail "policy omits /data/node contract: $term"
done

# Hermes must be a baked, offline Core, including the duplicate-CPython removal.
for term in 'No npm/uv/git/curl is invoked here' 'no network provisioning will be attempted'; do
  grep -Fq "$term" "$PROVISIONER" || fail "provisioner lost offline guarantee: $term"
done
for term in 'CPython 3.11 去重契约' 'manifest-verified 3.11' '不能再把同一' '联网 provision'; do
  grep -Fq "$term" "$POLICY" || fail "policy omits Hermes Core contract: $term"
done
grep -Fq 'remove only the manifest-verified Hermes 3.11 asset' "$CORE_BUILDER" ||
  fail "Core builder no longer removes the duplicate Hermes CPython archive"

# Keep all three documents aligned with the current signed-generation model.
for term in 'agent-runtime-version-policy.md' 'signed' 'generation' 'Hermes Core'; do
  grep -Eqi "$term" "$AGENTS" || fail "AGENTS.md omits current runtime term: $term"
done
for term in '签名' 'generation' 'Core-only' '真机'; do
  grep -Eqi "$term" "$README" || fail "README.md omits current runtime term: $term"
done

# These phrases describe the retired mutable-device lifecycle and must not
# survive in policy-facing docs.
if grep -Eqi 'npm i -g <pkg>@latest|首启.*按.*HERMES_NPM_VERSION.*重装|hermes update.*只会前进' "$POLICY" "$AGENTS" "$README"; then
  fail "documentation still advertises mutable on-device agent updates"
fi

echo "agent runtime documentation policy tests passed"
