#!/usr/bin/env bash
# Behavioral coverage for the first CI cache batch. Pure fixtures/mocks only;
# no network, no real credentials, no full build. Runs in 1-2 seconds.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/Scripts/wrt_cache_lib.sh"
RECLAIM="$ROOT_DIR/Scripts/wrt_cache_reclaim.sh"
GUARD="$ROOT_DIR/Scripts/wrt_cache_payload_guard.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for f in "$LIB" "$RECLAIM" "$GUARD"; do
	[ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
	bash -n "$f"
done
[ -f "$WORKFLOW" ] || { echo "missing workflow" >&2; exit 1; }

fail() { echo "cache lifecycle test FAILED: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCOPE_A="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SCOPE_B="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

# Build an identity manifest for a fixture case dir, using fixed labels.
build_manifest() {
	local c=$1 pkg=${2:-pkg-default} mode=${3:-prebuilt}
	{
		printf 'source\t%s\n' "$(bash "$LIB" file-digest "$c/repo_flag")"
		printf 'config/general\t%s\n' "$(bash "$LIB" file-digest "$c/GENERAL.txt")"
		printf 'config/device\t%s\n' "$(bash "$LIB" file-digest "$c/device.txt")"
		printf 'script/Packages.sh\t%s\n' "$(bash "$LIB" file-digest "$c/Packages.sh")"
		printf 'input/package\t%s\n' "$(printf '%s' "$pkg" | sha256sum | awk '{print $1}')"
		printf 'container/mode\t%s\n' "$(printf '%s' "$mode" | sha256sum | awk '{print $1}')"
		printf 'container/overlay\t%s\n' "$(bash "$LIB" tree-digest "$c/overlay")"
	}
}
scope_of() { build_manifest "$@" | bash "$LIB" scope; }

make_case() { # dir
	local c=$1
	mkdir -p "$c/overlay/etc"
	echo "repo/branch/aaaaaaaa11111111111111111111111111111111" > "$c/repo_flag"
	echo "CONFIG_CCACHE=y" > "$c/GENERAL.txt"
	echo "CONFIG_TARGET_X=y" > "$c/device.txt"
	echo "# packages" > "$c/Packages.sh"
	echo "ov" > "$c/overlay/etc/f"
}

echo "[1] identical content in different absolute dirs -> identical scope"
make_case "$TMP/work-a/checkout"
mkdir -p "$TMP/other-place/work-b"
cp -r "$TMP/work-a/checkout/." "$TMP/other-place/work-b/"
s_a="$(scope_of "$TMP/work-a/checkout")"
s_b="$(scope_of "$TMP/other-place/work-b")"
[ "$s_a" = "$s_b" ] || fail "scope drifted with absolute workspace path"
[ ${#s_a} -eq 64 ] || fail "scope is not a 64-char digest"

echo "[2] each key input changes the scope"
base="$s_a"
# source SHA change
sed -i 's/aaaaaaaa/bbbbbbbb/' "$TMP/other-place/work-b/repo_flag"
[ "$base" != "$(scope_of "$TMP/other-place/work-b")" ] || fail "source SHA change did not change scope"
cp "$TMP/work-a/checkout/repo_flag" "$TMP/other-place/work-b/repo_flag"
# device config change
echo "CONFIG_TARGET_Y=y" > "$TMP/other-place/work-b/device.txt"
[ "$base" != "$(scope_of "$TMP/other-place/work-b")" ] || fail "device config change did not change scope"
cp "$TMP/work-a/checkout/device.txt" "$TMP/other-place/work-b/device.txt"
# package selection change
[ "$base" != "$(scope_of "$TMP/other-place/work-b" pkg-other)" ] || fail "package change did not change scope"
# container mode change
[ "$base" != "$(scope_of "$TMP/other-place/work-b" pkg-default openwrt)" ] || fail "container mode change did not change scope"
# overlay content change
echo changed >> "$TMP/other-place/work-b/overlay/etc/f"
[ "$base" != "$(scope_of "$TMP/other-place/work-b")" ] || fail "overlay change did not change scope"

echo "[3] run/attempt make unique save keys; prefix stays stable"
mapfile -t k1 < <(bash "$LIB" keys devX "$SCOPE_A" 100 1)
mapfile -t k2 < <(bash "$LIB" keys devX "$SCOPE_A" 100 2)
mapfile -t k3 < <(bash "$LIB" keys devX "$SCOPE_A" 101 1)
[ "${k1[1]}" = "${k2[1]}" ] && [ "${k2[1]}" = "${k3[1]}" ] || fail "restore prefix must be stable across runs"
[ "${k1[2]}" != "${k2[2]}" ] || fail "run_attempt did not change save key"
[ "${k1[2]}" != "${k3[2]}" ] || fail "run_id did not change save key"
case "${k1[2]}" in "${k1[1]}"*) ;; *) fail "save key must start from the bounded prefix" ;; esac

echo "[4] miss / exact / prefix lifecycle and bounded prefix matching"
# Emulate actions/cache restore selection over an existing-generation list.
existing=(
	"devX-${SCOPE_A}-run90-at2"
	"devX-${SCOPE_A}-run95-at1"
	"devX-${SCOPE_B}-run95-at1"
)
select_latest_prefix() {
	local prefix=$1 best="" k
	for k in "${existing[@]}"; do
		case "$k" in
		"$prefix"*) best=$k ;;
		esac
	done
	printf '%s' "$best"
}
picked="$(select_latest_prefix "devX-${SCOPE_A}-run")"
[ "$picked" = "devX-${SCOPE_A}-run95-at1" ] || fail "prefix picked $picked (want newest same-scope)"
case "$picked" in *"$SCOPE_B"*) fail "bounded prefix crossed into another scope" ;; esac
[ -z "$(select_latest_prefix "devX-${SCOPE_A}-run000")" ] || fail "non-matching prefix must be a miss"
# exact primary hit
[ "${k1[2]}" = "devX-${SCOPE_A}-run100-at1" ] || fail "exact key mismatch"

echo "[5] a failed/absent save never deletes an existing cache"
if grep -Eq 'gh[[:space:]]+cache[[:space:]]+delete' "$WORKFLOW"; then
	fail "workflow must not delete caches to make room for a save"
fi
for s in "$LIB" "$RECLAIM" "$GUARD"; do
	if grep -Eq 'gh[[:space:]]+cache' "$s"; then
		fail "$s must not issue gh cache commands"
	fi
done

echo "[6] different devices/parallel jobs never share prefix or key"
mapfile -t ka < <(bash "$LIB" keys devA "$SCOPE_A" 1 1)
mapfile -t kb < <(bash "$LIB" keys devB "$SCOPE_A" 1 1)
[ "${ka[1]}" != "${kb[1]}" ] || fail "different devices share a restore prefix"
mapfile -t kc < <(bash "$LIB" keys devA "$SCOPE_B" 1 1)
[ "${ka[1]}" != "${kc[1]}" ] || fail "different scopes share a restore prefix"

echo "[7] save policy: only successful non-test, non-cancelled builds save"
[ "$(bash "$LIB" save-decision false success false)" = "save" ] || fail "should save"
for args in "true success false" "false failure false" "false success true" "false cancelled false" "false unknown false"; do
	out="$(bash "$LIB" save-decision $args)"
	case "$out" in skip:*) ;; *) fail "expected skip for [$args], got $out" ;; esac
done
# workflow gate mirrors the policy
grep -Fq "!cancelled() && steps.compile_firmware.outcome == 'success' && env.WRT_TEST != 'true'" "$WORKFLOW" \
	|| fail "workflow save gate missing"

echo "[8] disk sufficient -> caches retained; low -> ordered bounded reclaim"
build_fixture() {
	local root=$1
	mkdir -p "$root/tmp/go-build" "$root/dl/go-mod-cache" \
		"$root/staging_dir/host/bin" "$root/staging_dir/toolchain-arch" \
		"$root/build_dir/pkg" "$root/.ccache" "$root/feeds/x/.git"
	# 4 x 1MiB go-build files with distinct mtimes (oldest..newest)
	local i
	for i in 1 2 3 4; do
		head -c 1048576 /dev/zero > "$root/tmp/go-build/f$i"
		touch -d "2026-01-0$i 00:00" "$root/tmp/go-build/f$i"
	done
	head -c 2097152 /dev/zero > "$root/dl/go-mod-cache/mod"
	head -c 3145728 /dev/zero > "$root/dl/linux-6.6.tar.xz" # ordinary dl, protected
	echo hostcc > "$root/staging_dir/host/bin/ccache"
	echo toolchain > "$root/staging_dir/toolchain-arch/gcc"
	echo keep > "$root/build_dir/pkg/keep"
	echo cached > "$root/.ccache/cc"
	echo git > "$root/feeds/x/.git/config"
}

# 8a: sufficient disk (low-water 0) -> everything retained
F1="$TMP/sufficient"
build_fixture "$F1"
bash "$RECLAIM" reclaim --wrt-dir "$F1" --low-water-gb 0 --target-free-gb 0 \
	--go-build-max 1G --gomod-max 1G > "$TMP/rec1.log"
[ "$(find "$F1/tmp/go-build" -type f | wc -l)" -eq 4 ] || fail "sufficient disk must retain go-build"
[ -f "$F1/dl/linux-6.6.tar.xz" ] || fail "ordinary dl tarball removed on sufficient path"
grep -q "recovered ccache/Go caches retained" "$TMP/rec1.log" || fail "missing retain log"

# 8b: forced pressure (huge watermarks, tiny caps) -> prune only allow-listed
F2="$TMP/pressure"
build_fixture "$F2"
set +e
bash "$RECLAIM" reclaim --wrt-dir "$F2" --low-water-gb 999999 --target-free-gb 999999 \
	--go-build-max 2M --gomod-max 1M > "$TMP/rec2.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "expected distinctive exit 4 when still below low-water, got $rc"
# oldest two go-build files evicted (cap 2MiB), newest two retained
[ ! -f "$F2/tmp/go-build/f1" ] || fail "oldest go-build not evicted"
[ ! -f "$F2/tmp/go-build/f2" ] || fail "second-oldest go-build not evicted"
[ -f "$F2/tmp/go-build/f4" ] || fail "newest go-build must be retained"
# protected paths survive
[ -f "$F2/staging_dir/host/bin/ccache" ] || fail "staging_dir/host wrongly deleted"
[ -f "$F2/staging_dir/toolchain-arch/gcc" ] || fail "toolchain wrongly deleted"
[ -f "$F2/build_dir/pkg/keep" ] || fail "build_dir wrongly deleted"
[ "$(stat -c %s "$F2/dl/linux-6.6.tar.xz")" -eq 3145728 ] || fail "ordinary dl tarball touched"
[ -f "$F2/.ccache/cc" ] || fail ".ccache wrongly cleared (must use cap, not -C)"
grep -q "refusing unbounded cleanup" "$TMP/rec2.log" || fail "missing bounded-stop error"

# 8c: reclamation steps run in the declared order (host -> feeds -> ccache ->
# go-build -> gomod). Equal high watermarks walk every step, so their log order
# is observable.
order_log="$TMP/rec2.log"
prev=0
for marker in "host apt package cache" "feed .git metadata" "ccache evict" "after go-build prune" "after go-mod prune"; do
	line_no="$(grep -n "$marker" "$order_log" | head -1 | cut -d: -f1)"
	[ -n "$line_no" ] || fail "ordered reclaim missing step: $marker"
	[ "$line_no" -gt "$prev" ] || fail "reclaim step out of order: $marker"
	prev=$line_no
done

echo "[9] invalid config fails closed; self-hosted skips host cleanup; escapes blocked"
set +e
bash "$RECLAIM" reclaim --wrt-dir "$F1" --low-water-gb abc >/dev/null 2>&1; [ $? -eq 2 ] || fail "bad low-water accepted"
bash "$RECLAIM" reclaim --wrt-dir "$F1" --low-water-gb 20 --target-free-gb 1 >/dev/null 2>&1; [ $? -eq 2 ] || fail "target<low accepted"
bash "$RECLAIM" reclaim --wrt-dir "$F1" --go-build-max 9Z >/dev/null 2>&1; [ $? -eq 2 ] || fail "bad size accepted"
bash "$RECLAIM" reclaim --wrt-dir "$F1" --self-hosted maybe >/dev/null 2>&1; [ $? -eq 2 ] || fail "bad self-hosted accepted"
set -e
bash "$RECLAIM" reclaim --wrt-dir "$F1" --low-water-gb 999999 --target-free-gb 999999 \
	--self-hosted true > "$TMP/rec4.log" 2>&1 || true
grep -q "self-hosted runner: skipping host system cleanup" "$TMP/rec4.log" || fail "self-hosted host cleanup not skipped"
ln -s /etc/hostname "$F1/tmp/go-build/escape"
set +e
bash "$LIB" assert-within "$F1" "$F1/tmp/go-build/escape" >/dev/null 2>&1
[ $? -ne 0 ] || fail "symlink escape outside build root was allowed"
set -e

echo "[10] payload boundary: fake secrets/rootfs blocked; excluded dirs ignored"
P="$TMP/payload"
mkdir -p "$P/.ccache/sub" "$P/tmp/go-build" "$P/staging_dir/host/etc" \
	"$P/staging_dir/toolchain-x" "$P/dl/go-mod-cache" \
	"$P/staging_dir/target-arch/root/etc" "$P/bin/targets"
echo benign > "$P/.ccache/sub/a.o"
echo mod > "$P/dl/go-mod-cache/m.zip"
echo tool > "$P/staging_dir/toolchain-x/ld"
# A fake private key living in the EXCLUDED target rootfs must be ignored.
# Literal split so repo secret scanners never see a contiguous PEM marker.
echo "-----BEGIN ""OPENSSH PRIVATE KEY-----" > "$P/staging_dir/target-arch/root/etc/id_rsa"
echo firmware > "$P/bin/targets/x-sysupgrade.bin"
bash "$GUARD" manifest --wrt-dir "$P" > "$TMP/g1.log" 2>&1 || fail "benign whitelist must pass"
grep -q "payload boundary check passed" "$TMP/g1.log" || fail "benign pass message missing"

echo "-----BEGIN PRIVATE KEY-----" > "$P/.ccache/sub/leak.pem"
set +e
bash "$GUARD" manifest --wrt-dir "$P" > "$TMP/g2.log" 2>&1; rc=$?
set -e
[ "$rc" -eq 4 ] || fail "fake PEM in .ccache must be refused (rc 4), got $rc"
grep -q "leak.pem" "$TMP/g2.log" || fail "offender not named"
rm -f "$P/.ccache/sub/leak.pem"

echo "fake-token" > "$P/tmp/go-build/id_ed25519"
set +e
bash "$GUARD" manifest --wrt-dir "$P" >/dev/null 2>&1; [ $? -eq 4 ] || fail "secret-like filename must be refused"
set -e
rm -f "$P/tmp/go-build/id_ed25519"

printf 'MULTICA_TOKEN=hskey-auth-''xxxx\n' > "$P/staging_dir/host/etc/cfg"
set +e
bash "$GUARD" manifest --wrt-dir "$P" >/dev/null 2>&1; [ $? -eq 4 ] || fail "credential content must be refused"
set -e

# whitelist in guard must match the workflow save/restore path block
for rel in ".ccache" "staging_dir/host" "staging_dir/toolchain-*" "dl/go-mod-cache" "tmp/go-build"; do
	grep -Fq "./wrt/$rel" "$WORKFLOW" || fail "workflow cache path block missing ./wrt/$rel"
done
# and the risky whole-tree paths must not be cache entries (exact trimmed line)
grep -E '^[[:space:]]+\./wrt/' "$WORKFLOW" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sort -u > "$TMP/cachepaths.txt"
for bad in "./wrt/staging_dir" "./wrt/build_dir" "./wrt/files" "./wrt/bin"; do
	if grep -Fxq "$bad" "$TMP/cachepaths.txt"; then
		fail "must not cache whole tree $bad"
	fi
done

echo "cache lifecycle behavioral tests passed"
