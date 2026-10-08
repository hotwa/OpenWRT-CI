#!/bin/bash
# Restore one reviewed upstream workaround for the NSS candidate's PCI radio.
set -euo pipefail

if [ "${WRT_REQUIRED_DEVICE:-}" != jdcloud_re-cs-02 ] ||
   [ "${WRT_COMMIT:-}" != 0fb9b10cb9df51fb076470e1dd93d1c30dd89d83 ]; then
    exit 0
fi

root=${GITHUB_WORKSPACE:?}/${WRT_DIR:?}
recipe="$root/package/kernel/mac80211/Makefile"
source="$(dirname "$(realpath "$0")")/patches/990-ath11k-clamp-reg-rule-bandwidth.patch"
destination="$root/package/kernel/mac80211/patches/ath11k/990-ath11k-clamp-reg-rule-bandwidth.patch"
digest=dd4ad38515ad746630d28dae3669cfef7be3ddb6dc1fd552586a0cf137d1c38a

grep -Fxq 'PKG_SOURCE_VERSION:=7.2' "$recipe" &&
grep -Fxq 'PKG_HASH:=6ec76a4cb0988b5382b2fc5053610a56ada90b8ef6a5a4f2807cd433badb9454' "$recipe" || {
    echo 'ERROR: RE-CS-02 regulatory workaround requires reviewed backports 7.2' >&2
    exit 1
}
[ "$(sha256sum "$source" | cut -d ' ' -f1)" = "$digest" ] || {
    echo 'ERROR: reviewed regulatory patch digest mismatch' >&2
    exit 1
}
if [ -e "$destination" ]; then
    [ "$(sha256sum "$destination" | cut -d ' ' -f1)" = "$digest" ] || {
        echo 'ERROR: conflicting upstream regulatory patch; review before replacement' >&2
        exit 1
    }
else
    install -m 644 "$source" "$destination"
fi
echo 'RE-CS-02: restored reviewed ath11k regulatory bandwidth clamp'
