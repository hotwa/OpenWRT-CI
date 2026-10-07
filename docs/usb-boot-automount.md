# USB storage after boot

The normal early `fstab` boot pass and USB add-event handling remain in place.
RE-CS-02 cold-boot inspection found a recognized exFAT partition unmounted,
although replaying native mounting succeeded. The exact early-event failure
has not been established. `usb-boot-automount` adds a bounded late recovery
pass rather than claiming that the early-event race is proven.

The procd one-shot starts at S97, scans USB-backed `sd*` block devices for
about 60 seconds, and sends `ACTION=add DEVNAME=<device> block hotplug` only
for devices not already mounted. USB ancestry is verified in sysfs. Whole
partitioned disks, SATA, eMMC, rootfs/loop and USB network interfaces are
excluded. It never uses global `block mount`, formats disks, repairs a
filesystem, edits fstab, or creates SMB shares. The normal hotplug handler
continues to handle insertion after the startup window.

fstools retains ownership of mount policy. Existing per-device UUID/label
mappings and mount options are honored; with anonymous mounting enabled,
replacement disks use the ordinary `/mnt/<device>` target. The recovery code
contains no fixed UUID. A stable SMB/container path still needs administrator
configuration: mounting any replacement disk does not automatically authorize
it for an existing public/guest share or assign it to Garage.

Samba guest access, network exposure and filesystem integrity are independent
of mounting. Do not let dependent services write into an unmounted path on
internal storage. Safely unmount before removing a disk. Abrupt power loss
can still require a filesystem check; this worker never runs automatic repair.

Validation: `bash tests/test_usb_boot_automount.sh` covers USB partition and
superfloppy recovery, SATA/whole-disk exclusion, already-mounted idempotency,
delayed enumeration, native-policy refusal, bounded failures, overlapping
workers, empty devices, and firmware overlay wiring. Physical cold boot after
installing this generic worker remains a separate device check.
