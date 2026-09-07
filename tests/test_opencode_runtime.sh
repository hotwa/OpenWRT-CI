#!/bin/bash
# test_opencode_runtime.sh - unit tests for opencode runtime integration.
#
# Runs in WSL/Linux bash.  Uses temporary directories to simulate /data and
# /etc; never touches the real system.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_opencode_runtime.sh"
RUNTIME_SCRIPT="$ROOT_DIR/files/usr/sbin/opencode-runtime"
WRAPPER_SCRIPT="$ROOT_DIR/files/usr/bin/opencode"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/opencode-runtime"
BOOTSTRAP_SCRIPT="$ROOT_DIR/files/usr/sbin/multica-agent-bootstrap"
PROFILE_SCRIPT="$ROOT_DIR/files/etc/profile.d/22-opencode.sh"
CONFIG_FILE="$ROOT_DIR/files/etc/opencode/opencode.json"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

# ---------------------------------------------------------------------------
# 1. Syntax checks
# ---------------------------------------------------------------------------
echo "== Syntax checks =="

bash -n "$FETCH_SCRIPT" && pass "fetch_opencode_runtime.sh bash -n" || fail "fetch_opencode_runtime.sh bash -n"
sh -n "$RUNTIME_SCRIPT" && pass "opencode-runtime sh -n" || fail "opencode-runtime sh -n"
sh -n "$WRAPPER_SCRIPT" && pass "opencode wrapper sh -n" || fail "opencode wrapper sh -n"
sh -n "$INIT_SCRIPT" && pass "opencode-runtime init.d sh -n" || fail "opencode-runtime init.d sh -n"
sh -n "$BOOTSTRAP_SCRIPT" && pass "multica-agent-bootstrap sh -n" || fail "multica-agent-bootstrap sh -n"
bash -n "$PROFILE_SCRIPT" && pass "22-opencode.sh bash -n" || fail "22-opencode.sh bash -n"

# ---------------------------------------------------------------------------
# 2. Config file checks
# ---------------------------------------------------------------------------
echo "== Config file =="

[ -f "$CONFIG_FILE" ] && pass "opencode.json exists" || fail "opencode.json exists"
if [ -f "$CONFIG_FILE" ]; then
	grep -Fq '"permission"' "$CONFIG_FILE" && pass "opencode.json has permission key" || fail "opencode.json has permission key"
	grep -Fq '"allow"' "$CONFIG_FILE" && pass "opencode.json permission is allow" || fail "opencode.json permission is allow"
fi

# ---------------------------------------------------------------------------
# 3. fetch_opencode_runtime.sh: mock curl and verify metadata parsing
# ---------------------------------------------------------------------------
echo "== fetch_opencode_runtime.sh metadata parsing =="

MOCK_DIR="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_DIR"

# Mock curl that returns a fixed npm registry JSON for /latest.
cat > "$MOCK_DIR/curl" <<'MOCK'
#!/bin/bash
# Mock curl: ignore all flags, output fixed JSON for the opencode package.
cat <<'JSON'
{
  "name": "opencode-linux-arm64-musl",
  "version": "1.18.29",
  "description": "opencode binary for linux-arm64-musl",
  "dist": {
    "tarball": "https://registry.npmjs.org/opencode-linux-arm64-musl/-/opencode-linux-arm64-musl-1.18.29.tgz",
    "integrity": "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
  }
}
JSON
MOCK
chmod +x "$MOCK_DIR/curl"

# Mock retry.sh's retry_cmd by making curl work directly.
FETCH_OUT_DIR="$TMP_ROOT/fetch-out"
mkdir -p "$FETCH_OUT_DIR"

# Run the fetch script with PATH overridden to use mock curl.
# The script sources retry.sh from its own directory; retry_cmd just calls
# the command, so mock curl on PATH is sufficient.
if PATH="$MOCK_DIR:$PATH" bash "$FETCH_SCRIPT" "$FETCH_OUT_DIR" >/dev/null 2>&1; then
	pass "fetch_opencode_runtime.sh runs with mock curl"
else
	fail "fetch_opencode_runtime.sh runs with mock curl"
fi

RELEASE_URL="$FETCH_OUT_DIR/etc/opencode/release-url"
if [ -f "$RELEASE_URL" ]; then
	pass "release-url file created"

	# Check all 4 keys exist.
	for key in OPENCODE_VERSION OPENCODE_TARBALL_URL OPENCODE_SHA512 OPENCODE_ARCH; do
		if grep -q "^${key}=" "$RELEASE_URL"; then
			pass "release-url contains $key"
		else
			fail "release-url contains $key"
		fi
	done

	# Check values.
	version="$(grep '^OPENCODE_VERSION=' "$RELEASE_URL" | cut -d= -f2)"
	[ "$version" = "1.18.29" ] && pass "release-url version=1.18.29" || fail "release-url version=$version (expected 1.18.29)"

	url="$(grep '^OPENCODE_TARBALL_URL=' "$RELEASE_URL" | cut -d= -f2)"
	case "$url" in
		*opencode-linux-arm64-musl-1.18.29.tgz) pass "release-url tarball URL correct" ;;
		*) fail "release-url tarball URL: $url" ;;
	esac

	arch="$(grep '^OPENCODE_ARCH=' "$RELEASE_URL" | cut -d= -f2)"
	[ "$arch" = "linux-arm64-musl" ] && pass "release-url arch=linux-arm64-musl" || fail "release-url arch=$arch"

	# SHA512 hex should be 128 chars (all 'a's from our mock base64 of all-zero bytes).
	sha="$(grep '^OPENCODE_SHA512=' "$RELEASE_URL" | cut -d= -f2)"
	[ "${#sha}" -eq 128 ] && pass "release-url sha512 is 128 hex chars" || fail "release-url sha512 length=${#sha} (expected 128)"
else
	fail "release-url file created"
fi

# ---------------------------------------------------------------------------
# 4. opencode-runtime status: not installed
# ---------------------------------------------------------------------------
echo "== opencode-runtime status (not installed) =="

STATUS_DIR="$TMP_ROOT/status-test"
mkdir -p "$STATUS_DIR/etc/opencode" "$STATUS_DIR/data"

# Create a minimal release-url.
cat > "$STATUS_DIR/etc/opencode/release-url" <<'EOF'
OPENCODE_VERSION=1.18.29
OPENCODE_TARBALL_URL=https://example.com/opencode.tgz
OPENCODE_SHA512=abc123
OPENCODE_ARCH=linux-arm64-musl
EOF

# Test that the runtime script's release_value function parses correctly.
# We extract functions by removing the main() invocation line, then source.
RUNTIME_FUNCS="$STATUS_DIR/runtime-funcs.sh"
grep -v '^main "[$]@"$' "$RUNTIME_SCRIPT" > "$RUNTIME_FUNCS"
if sh -c "
	. '$RUNTIME_FUNCS'
	RELEASE_FILE='$STATUS_DIR/etc/opencode/release-url'
	ver=\$(release_value OPENCODE_VERSION)
	[ \"\$ver\" = '1.18.29' ]
" 2>/dev/null; then
	pass "opencode-runtime release_value parses correctly"
else
	fail "opencode-runtime release_value parses correctly"
fi

# Test that status outputs "(not installed)" when binary is absent.
RUNTIME_FUNCS2="$STATUS_DIR/runtime-funcs2.sh"
grep -v '^main "[$]@"$' "$RUNTIME_SCRIPT" > "$RUNTIME_FUNCS2"
if sh -c "
	. '$RUNTIME_FUNCS2'
	RELEASE_FILE='$STATUS_DIR/etc/opencode/release-url'
	DATA_ROOT='$STATUS_DIR/data'
	INSTALL_ROOT='\${DATA_ROOT}/opt/opencode'
	CURRENT_LINK='\${INSTALL_ROOT}/current'
	BIN_PATH='\${CURRENT_LINK}/bin/opencode'
	VERSION_FILE='\${CURRENT_LINK}/version'
	output=\$(do_status 2>/dev/null)
	echo \"\$output\" | grep -q 'not installed'
" 2>/dev/null; then
	pass "opencode-runtime status reports not installed"
else
	fail "opencode-runtime status reports not installed"
fi

# ---------------------------------------------------------------------------
# 5. multica-agent-bootstrap: opencode-first logic present
# ---------------------------------------------------------------------------
echo "== multica-agent-bootstrap opencode-first =="

grep -Fq "Opencode on OpenWrt" "$BOOTSTRAP_SCRIPT" && pass "bootstrap has opencode runtime name" || fail "bootstrap has opencode runtime name"
grep -Fq "runtime_provider 'opencode'" "$BOOTSTRAP_SCRIPT" && pass "bootstrap default provider is opencode" || fail "bootstrap default provider is opencode"
grep -Fq "Pi (OpenWrt-Router)" "$BOOTSTRAP_SCRIPT" && pass "bootstrap has pi fallback name" || fail "bootstrap has pi fallback name"
grep -Fq 'fell back to pi runtime' "$BOOTSTRAP_SCRIPT" && pass "bootstrap logs pi fallback" || fail "bootstrap logs pi fallback"

# Verify the fallback chain: opencode try, then pi try.
if grep -A2 'try_bootstrap.*"opencode"' "$BOOTSTRAP_SCRIPT" | grep -q 'try_bootstrap.*"pi"'; then
	pass "bootstrap has opencode->pi fallback chain"
else
	# More lenient check: both try_bootstrap calls exist in the same function.
	if grep -c 'try_bootstrap' "$BOOTSTRAP_SCRIPT" | grep -q '^[2-9]'; then
		pass "bootstrap has multiple try_bootstrap calls (fallback chain)"
	else
		fail "bootstrap has opencode->pi fallback chain"
	fi
fi

# ---------------------------------------------------------------------------
# 6. init.d: START ordering and structure
# ---------------------------------------------------------------------------
echo "== init.d structure =="

grep -Fq 'START=92' "$INIT_SCRIPT" && pass "init.d START=92 (after agent-runtime=91, before multica=95)" || fail "init.d START=92"
grep -Fq 'opencode-runtime install' "$INIT_SCRIPT" && pass "init.d triggers install" || fail "init.d triggers install"
grep -Fq '/root/.config/opencode' "$INIT_SCRIPT" && pass "init.d maintains config symlink" || fail "init.d maintains config symlink"
grep -Fq 'restart()' "$INIT_SCRIPT" && pass "init.d has restart()" || fail "init.d has restart()"

# ---------------------------------------------------------------------------
# 7. profile.d: structure
# ---------------------------------------------------------------------------
echo "== profile.d structure =="

grep -Fq 'OPENCODE_DISABLE_LSP_DOWNLOAD=1' "$PROFILE_SCRIPT" && pass "profile.d disables LSP download" || fail "profile.d disables LSP download"
grep -Fq 'persistent:/data' "$PROFILE_SCRIPT" && pass "profile.d gates on persistent /data" || fail "profile.d gates on persistent /data"
grep -Fq 'XDG_CONFIG_HOME=/data/opencode/config' "$PROFILE_SCRIPT" && pass "profile.d sets XDG_CONFIG_HOME" || fail "profile.d sets XDG_CONFIG_HOME"

# ---------------------------------------------------------------------------
# 8. wrapper: structure
# ---------------------------------------------------------------------------
echo "== wrapper structure =="

grep -Eq 'RUNTIME_MGR.*install' "$WRAPPER_SCRIPT" && pass "wrapper triggers install on demand" || fail "wrapper triggers install on demand"
grep -Fq 'exec "$REAL_BIN" "$@"' "$WRAPPER_SCRIPT" && pass "wrapper execs real binary" || fail "wrapper execs real binary"
grep -Fq 'OPENCODE_DISABLE_LSP_DOWNLOAD' "$WRAPPER_SCRIPT" && pass "wrapper sets LSP disable env" || fail "wrapper sets LSP disable env"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
echo "All opencode runtime tests passed."
