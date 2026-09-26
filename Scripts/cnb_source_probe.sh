#!/usr/bin/env bash
# Non-secret CNB phase-1 probe: reproduce source SHA and feed acquisition only.
# Does not generate a firmware image or stage private overlays.
set -euo pipefail
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN
export GIT_TERMINAL_PROMPT=0
workspace="$(pwd -P)"
[ -f "$workspace/.github/workflows/RE-CS-07-BUILD.yml" ] || {
  echo 'ERROR: repository checkout is missing' >&2; exit 1;
}
python3 "$workspace/Scripts/cnb_re_profile_preflight.py"
pin="$(python3 -c 'from Scripts.cnb_re_profile_preflight import PIN; print(PIN)')"
[ "${#pin}" -eq 40 ] || { echo 'ERROR: invalid source pin' >&2; exit 1; }
repo='https://github.com/VIKINGYFY/immortalwrt.git'
source_dir="$workspace/wrt"
[ ! -e "$source_dir" ] || { echo 'ERROR: source directory already exists; refuse reuse' >&2; exit 1; }

if ! command -v git >/dev/null || ! command -v perl >/dev/null || \
   ! command -v rsync >/dev/null || ! command -v gawk >/dev/null; then
  [ "$(id -u)" -eq 0 ] || { echo 'ERROR: installing git/perl requires root' >&2; exit 1; }
  export SUDO=''
  . "$workspace/Scripts/ci-apt-lib.sh"
  aptx_update
  aptx_retry install -y git perl ca-certificates rsync gawk
fi
. "$workspace/Scripts/retry.sh"
retry_cmd 5 15 git clone --depth=1 --single-branch --branch main "$repo" "$source_dir"
retry_cmd 5 15 git -C "$source_dir" fetch --depth=1 origin "$pin"
git -C "$source_dir" checkout --detach "$pin"
resolved="$(git -C "$source_dir" rev-parse HEAD)"
[ "$resolved" = "$pin" ] || { echo 'ERROR: checkout does not match pinned SHA' >&2; exit 1; }
"$workspace/Scripts/patch_libiwrt_k612_cacheline_assert.sh" "$source_dir" 'VIKINGYFY/immortalwrt' main
"$workspace/Scripts/fix_qca8k_assisted_learning_patch.sh" "$source_dir"
printf '%s\n' "$repo/main/$resolved" > "$workspace/repo_flag"
[ -d "$source_dir/package/qca-nss" ] || { echo 'ERROR: pinned NSS package tree absent' >&2; exit 1; }
(
  cd "$source_dir"
  retry_cmd 5 15 ./scripts/feeds update -a
  retry_cmd 5 15 ./scripts/feeds install -a
  # feeds install may exit 0 even when OpenWrt's prerequisite make failed.
  # Never mistake that for a usable package metadata graph.
  [ -s ./tmp/.packageinfo ] && [ -s ./tmp/.targetinfo ] || {
    echo 'ERROR: feeds returned success without required package/target metadata' >&2
    exit 1
  }
)
[ -s "$source_dir/feeds/packages/net/samba4/Makefile" ] || {
  echo 'ERROR: Samba package feed unavailable after sync' >&2; exit 1;
}
echo "CNB source/feeds probe passed at pinned SHA $resolved (no firmware or device operation)"
