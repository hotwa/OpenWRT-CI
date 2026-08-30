#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/GuardReCs07Artifact.sh"
DEVICE='jdcloud_re-cs-07'

[ -f "$SCRIPT" ] || { echo "missing GuardReCs07Artifact.sh"; exit 1; }
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/.config" <<'EOT'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07=y
CONFIG_PACKAGE_gre=y
CONFIG_PACKAGE_luci-proto-gre=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_luci-app-wrtbak=y
CONFIG_PACKAGE_vm103-failover=y
EOT
bash "$SCRIPT" defconfig "$WORK_DIR/.config" "$DEVICE"

cat >"$WORK_DIR/re-cs-02.config" <<'EOT'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y
CONFIG_PACKAGE_luci-app-openclaw=y
CONFIG_PACKAGE_luci-app-wrtbak=y
EOT
bash "$SCRIPT" defconfig "$WORK_DIR/re-cs-02.config" jdcloud_re-cs-02

grep -v '^CONFIG_PACKAGE_luci-app-openclaw=y$' "$WORK_DIR/re-cs-02.config" >"$WORK_DIR/re-cs-02-missing.config"
! bash "$SCRIPT" defconfig "$WORK_DIR/re-cs-02-missing.config" jdcloud_re-cs-02 >/dev/null 2>&1
! bash "$SCRIPT" defconfig "$WORK_DIR/re-cs-02.config" jdcloud_re-ss-01 >/dev/null 2>&1

cat >"$WORK_DIR/re-ss-01.config" <<'EOT'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y
CONFIG_PACKAGE_luci-app-wrtbak=y
EOT
bash "$SCRIPT" defconfig "$WORK_DIR/re-ss-01.config" jdcloud_re-ss-01
printf '%s\n' 'CONFIG_PACKAGE_luci-app-openclaw=y' >>"$WORK_DIR/re-ss-01.config"
bash "$SCRIPT" defconfig "$WORK_DIR/re-ss-01.config" jdcloud_re-ss-01

mkdir -p "$WORK_DIR/bin/targets/qualcommax/ipq60xx" "$WORK_DIR/upload"
printf 'firmware\n' >"$WORK_DIR/bin/targets/qualcommax/ipq60xx/openwrt-qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-sysupgrade.bin"
printf 'factory firmware\n' >"$WORK_DIR/bin/targets/qualcommax/ipq60xx/openwrt-qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-factory.bin"
cat >"$WORK_DIR/bin/targets/qualcommax/ipq60xx/qualcommax-ipq60xx-generic.manifest" <<'EOT'
gre - 1
luci-proto-gre - 1
ip-full - 1
luci-app-wrtbak - 1
vm103-failover - 1
EOT
cp "$WORK_DIR/.config" "$WORK_DIR/upload/Config-IPQ60XX-RE-CS-07-NOWIFI.txt"
bash "$SCRIPT" stage "$WORK_DIR/bin/targets" "$WORK_DIR/upload" "$DEVICE"
bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE"
[ "$(find "$WORK_DIR/upload" -maxdepth 1 -type f | wc -l)" -eq 5 ]
(cd "$WORK_DIR/upload" && sha256sum -c SHA256SUMS >/dev/null)

# Verification rejects a manifest missing the topology-specific package.
cp -a "$WORK_DIR/upload" "$WORK_DIR/missing-package-upload"
sed -i '/^vm103-failover[[:space:]]/d' "$WORK_DIR/missing-package-upload/qualcommax-ipq60xx-generic.manifest"
if bash "$SCRIPT" verify "$WORK_DIR/missing-package-upload" "$DEVICE" >"$WORK_DIR/missing-package.err" 2>&1; then
	echo "artifact guard accepted a manifest without vm103-failover"
	exit 1
fi
grep -Fq 'manifest is missing required package: vm103-failover' "$WORK_DIR/missing-package.err"

# Verification rejects nested paths, even when the four top-level files are valid.
mkdir -p "$WORK_DIR/upload/nested"
printf 'unexpected\n' >"$WORK_DIR/upload/nested/file"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
rm -rf "$WORK_DIR/upload/nested"

# SHA256SUMS must contain exactly all artifact payload names.
cp "$WORK_DIR/upload/SHA256SUMS" "$WORK_DIR/SHA256SUMS.good"
sed -n '1,2p' "$WORK_DIR/SHA256SUMS.good" >"$WORK_DIR/upload/SHA256SUMS"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"
printf '%064d  extra-file\n' 0 >>"$WORK_DIR/upload/SHA256SUMS"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"

# Duplicate and non-basename checksum entries are rejected before hash checking.
head -n 1 "$WORK_DIR/SHA256SUMS.good" >>"$WORK_DIR/upload/SHA256SUMS"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"
printf '%064d  ../outside\n' 0 >>"$WORK_DIR/upload/SHA256SUMS"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"

# An extra payload fails both when omitted from and included in SHA256SUMS.
printf 'unexpected\n' >"$WORK_DIR/upload/unlisted.txt"
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
(cd "$WORK_DIR/upload" && sha256sum unlisted.txt >>SHA256SUMS)
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
rm "$WORK_DIR/upload/unlisted.txt"
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"

# A sysupgrade-only artifact is never accepted.
factory_name="$(find "$WORK_DIR/upload" -maxdepth 1 -type f -name '*factory*.bin' -printf '%f\n' | head -n 1)"
mv "$WORK_DIR/upload/$factory_name" "$WORK_DIR/$factory_name"
(cd "$WORK_DIR/upload" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum -- >SHA256SUMS)
! bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE" >/dev/null 2>&1
mv "$WORK_DIR/$factory_name" "$WORK_DIR/upload/$factory_name"
cp "$WORK_DIR/SHA256SUMS.good" "$WORK_DIR/upload/SHA256SUMS"

cp "$WORK_DIR/.config" "$WORK_DIR/multi.config"
printf '%s\n' 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y' >>"$WORK_DIR/multi.config"
! bash "$SCRIPT" defconfig "$WORK_DIR/multi.config" "$DEVICE" >/dev/null 2>&1
grep -v '^CONFIG_PACKAGE_gre=y$' "$WORK_DIR/.config" >"$WORK_DIR/missing.config"
! bash "$SCRIPT" defconfig "$WORK_DIR/missing.config" "$DEVICE" >/dev/null 2>&1
grep -v '^CONFIG_PACKAGE_vm103-failover=y$' "$WORK_DIR/.config" >"$WORK_DIR/missing-vm103.config"
! bash "$SCRIPT" defconfig "$WORK_DIR/missing-vm103.config" "$DEVICE" >/dev/null 2>&1
bash "$SCRIPT" verify "$WORK_DIR/upload" "$DEVICE"

# Stage rejects a non-flat upload staging tree.
mkdir -p "$WORK_DIR/nested-upload/nested"
cp "$WORK_DIR/.config" "$WORK_DIR/nested-upload/Config-IPQ60XX-RE-CS-07-NOWIFI.txt"
printf 'unexpected\n' >"$WORK_DIR/nested-upload/nested/file"
! bash "$SCRIPT" stage "$WORK_DIR/bin/targets" "$WORK_DIR/nested-upload" "$DEVICE" >/dev/null 2>&1

# A unique generic manifest in a stale sibling directory is not bound to the image.
mkdir -p "$WORK_DIR/wrong-source/device" "$WORK_DIR/wrong-source/wrong/stale" "$WORK_DIR/wrong-upload"
cp "$WORK_DIR/bin/targets/qualcommax/ipq60xx/"*jdcloud_re-cs-07*.bin "$WORK_DIR/wrong-source/device/"
cp "$WORK_DIR/bin/targets/qualcommax/ipq60xx/"*.manifest "$WORK_DIR/wrong-source/wrong/stale/"
cp "$WORK_DIR/.config" "$WORK_DIR/wrong-upload/Config-IPQ60XX-RE-CS-07-NOWIFI.txt"
! bash "$SCRIPT" stage "$WORK_DIR/wrong-source" "$WORK_DIR/wrong-upload" "$DEVICE" >/dev/null 2>&1

# Staging also rejects build output that has only a sysupgrade image.
mkdir -p "$WORK_DIR/sysupgrade-only-source" "$WORK_DIR/sysupgrade-only-upload"
cp "$WORK_DIR/bin/targets/qualcommax/ipq60xx/"*jdcloud_re-cs-07*sysupgrade.bin "$WORK_DIR/sysupgrade-only-source/"
cp "$WORK_DIR/bin/targets/qualcommax/ipq60xx/"*.manifest "$WORK_DIR/sysupgrade-only-source/"
cp "$WORK_DIR/.config" "$WORK_DIR/sysupgrade-only-upload/Config-IPQ60XX-RE-CS-07-NOWIFI.txt"
! bash "$SCRIPT" stage "$WORK_DIR/sysupgrade-only-source" "$WORK_DIR/sysupgrade-only-upload" "$DEVICE" >/dev/null 2>&1

printf 'other firmware\n' >"$WORK_DIR/bin/targets/qualcommax/ipq60xx/openwrt-qualcommax-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade.bin"
mkdir "$WORK_DIR/unexpected-device-upload"
cp "$WORK_DIR/.config" "$WORK_DIR/unexpected-device-upload/Config-IPQ60XX-RE-CS-07-NOWIFI.txt"
! bash "$SCRIPT" stage "$WORK_DIR/bin/targets" "$WORK_DIR/unexpected-device-upload" "$DEVICE" >/dev/null 2>&1

echo "RE-CS-07 artifact guard tests passed"
