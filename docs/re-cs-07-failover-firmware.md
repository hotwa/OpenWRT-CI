# RE-CS-07 disaster-recovery firmware

## Phase-one boundary

This workflow produces a dedicated, build-only image for
`jdcloud_re-cs-07`. GitHub Actions builds and uploads the artifact; it does
not release firmware, connect to the router, or perform a remote flash.

The recovery model has four separate layers:

1. **Dedicated firmware package** — one RE-CS-07 sysupgrade image, its
   manifest, the final build config, and `SHA256SUMS`.
2. **Canonical wrtbak R2 backup** — the authoritative configuration backup,
   addressed by the stable alias `home-re-cs-07`.
3. **keep-config** — a normal sysupgrade may retain the current local
   configuration, but this is not a substitute for a verified backup.
4. **Local human confirmation** — a person on site confirms device identity,
   power/network readiness, and the intended recovery mode before flashing or
   restoring.

Regular upgrades keep wrtbak first-boot automatic restore disabled. A disaster
recovery restore must pass three gates before any write: the observed device
UID must match the intended backup identity, the backup manifest must match the
device and requested restore scope, and a readback/dry-run must show the exact
objects that will be restored. A mismatch stops recovery for manual review.

## Artifact guard

When `WRT_EXPECTED_DEVICE` is set, WRT-CORE verifies the post-defconfig
selection and then stages a strict four-file artifact. The config must select
only `jdcloud_re-cs-07`; the manifest must include `gre`,
`luci-proto-gre`, `ip-full`, and `luci-app-wrtbak`. Factory, initramfs,
rootfs, and other-device outputs are rejected.

## Phase two

`vm103-failover` is intentionally not selected in phase one because the
package does not exist yet. Phase two must begin with evidence collected from
the live router scripts and a known-good backup: interface naming, GRE setup,
route/rule ordering, health probes, failover/failback timing, persisted state,
and rollback behavior. Only after that evidence is reviewed should the logic
be packaged as `vm103-failover`; its package and runtime assertions can then
be added to the defconfig and manifest guard.
