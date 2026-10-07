#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/class" "$t/devices/usb1/block/sda/sda1" "$t/devices/sata/block/sdb/sdb1" "$t/devices/usb2/block/sdc" "$t/bin"
touch "$t/devices/usb1/block/sda/sda1/partition" "$t/devices/sata/block/sdb/sdb1/partition"
ln -s "$t/devices/usb1/block/sda" "$t/class/sda"
ln -s "$t/devices/usb1/block/sda/sda1" "$t/class/sda1"
ln -s "$t/devices/sata/block/sdb/sdb1" "$t/class/sdb1"
ln -s "$t/devices/usb2/block/sdc" "$t/class/sdc"
: > "$t/mounts"; : > "$t/events"
cat > "$t/bin/block" <<'MOCK'
#!/bin/sh
[ "$1" = hotplug ] && [ "$ACTION" = add ] || exit 9
printf '%s\n' "$DEVNAME" >> "$EVENTS"
# Simulate fstools declining a device (disabled/unsupported policy).
[ "${DENY:-}" != "$DEVNAME" ] || exit 1
printf '/dev/%s /mnt/%s exfat rw 0 0\n' "$DEVNAME" "$DEVNAME" >> "$USB_BOOT_MOUNTS"
MOCK
cat > "$t/bin/sleep" <<'MOCK'
#!/bin/sh
if [ -n "${DELAYED:-}" ]; then
 ln -sf "$DELAYED" "$USB_BOOT_SYS/sdd1"
fi
MOCK
chmod +x "$t/bin/"*
export USB_BOOT_SYS="$t/class" USB_BOOT_MOUNTS="$t/mounts" USB_BOOT_BLOCK="$t/bin/block" USB_BOOT_LOCK="$t/lock" USB_BOOT_PASSES=2 USB_BOOT_INTERVAL=0 EVENTS="$t/events"
export PATH="$t/bin:$PATH"
sh "$root/files/usr/sbin/usb-boot-automount"
printf 'sda1\nsdc\n' > "$t/expected"
cmp "$t/events" "$t/expected"
# Already-mounted devices must never be remounted, even across worker runs.
sh "$root/files/usr/sbin/usb-boot-automount"
cmp "$t/events" "$t/expected"
# A USB partition appearing after the first pass is recovered; any UUID works.
mkdir -p "$t/devices/usb3/block/sdd/sdd1"
touch "$t/devices/usb3/block/sdd/sdd1/partition"
export DELAYED="$t/devices/usb3/block/sdd/sdd1"
sh "$root/files/usr/sbin/usb-boot-automount"
[ "$(tail -1 "$t/events")" = sdd1 ]
unset DELAYED
# No policy bypass when fstools refuses to mount; failed calls are bounded.
sed -i '/sdd1/d' "$t/mounts"
export DENY=sdd1
sh "$root/files/usr/sbin/usb-boot-automount"
[ "$(grep -c '^sdd1$' "$t/events")" = 3 ]
! grep -q sdd1 "$t/mounts"
# Lock prevents overlapping workers; malformed bounds fail closed.
mkdir "$t/lock"; before=$(wc -l < "$t/events")
sh "$root/files/usr/sbin/usb-boot-automount"
[ "$(wc -l < "$t/events")" = "$before" ]; rmdir "$t/lock"
if USB_BOOT_PASSES=999 sh "$root/files/usr/sbin/usb-boot-automount"; then exit 1; fi
# Empty/no-USB system is harmless. CI must install+enable all executable files.
rm "$t/class/"*; : > "$t/events"
sh "$root/files/usr/sbin/usb-boot-automount"
[ ! -s "$t/events" ]
for file in usr/sbin/usb-boot-automount etc/init.d/usb-boot-automount etc/uci-defaults/98-enable-usb-boot-automount; do
 test -x "$root/files/$file"
 grep -Fq "cp -f ./files/$file ./wrt/files/$file" "$root/.github/workflows/WRT-CORE.yml"
done
! grep -Eq 'D21B|kioxia|garage|samba' "$root/files/usr/sbin/usb-boot-automount"
echo 'USB boot automount regression cases passed'
