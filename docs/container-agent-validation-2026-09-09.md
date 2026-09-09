# Container bridge and Agent context validation (2026-09-09)

## Scope and evidence levels

This change prepares a TEST-gated container fix and Agent environment/context
improvements for a new three-target firmware build. It is not a claim of
flashed-firmware or cold-boot acceptance. Kernel/source/runtime pins and existing
RE-Mesh/RE-CS-07 TEST=true callers are unchanged.

| Device | Live WAN | Read-only check of final bridge guard | Full patch installed by this task |
| --- | --- | --- | --- |
| RE-CS-02, 192.168.11.1 | PPPoE | Pass, managed local bridge gateway | No |
| RE-SS-01, 192.168.12.1 | PPPoE | Pass, active PPPoE default route | No |
| RE-CS-07, 192.168.10.1 | DHCP | Pass; helper/init shell syntax also passed | No |

All three report Linux 6.18.39, containerd 2.3.3 and nerdctl 2.3.5, with
containerd running and a real ext4 `/data` mount. The final local helper was
streamed through SSH into a temporary shell function and only its read-only
route predicate was called. No bridge enable, service restart, image pull,
firewall modification or firmware flashing was performed. RE-CS-07 first-use
SSH host trust was explicitly authorized by the user.

## Agent context findings and changes

RE-CS-07's running Multica daemon had CWD `/` and a PATH missing `/usr/sbin`
and `/sbin`, even though its SSH login shell could find rsync, rclone, uv,
node, pi, opencode and multica under `/usr/bin`.

- Multica now shares a generation-first complete PATH across role discovery,
  daemon and bootstrap. Native sbin tools are not mistaken for missing packages.
- The daemon starts in its configured `/data` workspace root; task-level CWD
  and writes still need verification. This is not a filesystem sandbox.
- The dynamic role card reports actual discovered tool paths, missing-command
  status and configured workspace root. Discovery does not execute OpenCode's
  possibly installing wrapper.
- Pi's installed resource-loader was inspected read-only and supports global
  `APPEND_SYSTEM.md` discovery, subject to local/explicit overrides.
- OpenCode's flat role link did not match its wrapper's XDG layout. The correct
  app directory is `/data/opencode/config/opencode`; init, Multica and firstboot
  now agree on it. Administrator-owned instructions/links are preserved.
- Multica server-side `--instructions`, local Pi/CommandCode/OpenCode role
  files, and shared Skills/MCP loading are distinct mechanisms. No live model
  session was invoked to claim end-to-end context consumption.

## Local and CI verification

Targeted shell fixtures cover bridge selection (36 cases), kernel routes in
isolated system/BusyBox shells, CNI/nft/UCI failure propagation, init escape,
TEST staging, PATH/CWD argv handling, role-link preservation, OpenCode runtime,
Multica lifecycle, data preparation, shared tools and runtime documentation
policy. These run without relying on unrelated uncommitted CI/cache edits.

Before release, complete the on-device/artifact gates in
[container-runtime-test.md](container-runtime-test.md#acceptance-boot-recovery-and-registry-fallback),
especially cold boot, restart-policy recovery, genuine official-down mirror
fallback, failure injection, and TEST=false/true rootfs inspection. After
deployment also verify the actual daemon PATH/CWD, effective OpenCode AGENTS
link, generated tool catalog, and a user-authorized harmless Agent task that
reports its working directory and available tools.
