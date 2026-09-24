# OpenWrt Fleet Identity and Future CD Policy

This document is the authoritative fleet registry and deployment contract. It
records identifiers and safety boundaries only; it contains no Headscale API
key, SSH private key, subscription URL, or other secret.

The repository provides a manual, default-off deployment gate. A daily
candidate build and a real device deployment remain deliberately separate
decisions.

## 1. Stable device identity

Every router has three distinct identities:

1. **model** — the exact firmware board/image family;
2. **LAN CIDR** — the exact subnet the router advertises; and
3. **Tailnet identity** — the cryptographic state at
   `/data/tailscale/tailscaled.state`.

The short, human-facing MagicDNS label combines only the first two:

```text
<model-short>-<LAN IPv4 third octet>
```

`model-short` removes the common `re-` prefix and punctuation, while retaining
the device family and model number. The final numeric component is always the
third octet of the router's active LAN IPv4 address, not its WAN address.

Examples:

| Model | LAN address | Short ID | MagicDNS FQDN |
| --- | --- | --- | --- |
| RE-CS-07 | `192.168.10.1` | `cs07-10` | `cs07-10.hs.jmsu.top` |
| RE-CS-02 | `192.168.11.1` | `cs02-11` | `cs02-11.hs.jmsu.top` |
| RE-SS-01 | `192.168.12.1` | `ss01-12` | `ss01-12.hs.jmsu.top` |

The model is **not** inferred from the subnet. For example, either
`cs07-13.hs.jmsu.top` or `ss01-13.hs.jmsu.top` is valid, but only after the
chosen model/CIDR combination is added to the registry. A future node at
`192.168.14.1` is likewise an unassigned slot until explicitly registered.

Two devices with the same model and same third octet are rejected. Adding an
automatic `-1` suffix is prohibited: it hides both a MagicDNS collision and an
overlapping-LAN deployment error.

## 2. Initial registry

Only these entries are approved initially. A deployment must use the exact
board, advertised CIDR, and FQDN from this table.

| ID | Model | Board name | LAN CIDR | MagicDNS |
| --- | --- | --- | --- | --- |
| `cs07-10` | RE-CS-07 | `jdcloud,re-cs-07` | `192.168.10.0/24` | `cs07-10.hs.jmsu.top` |
| `cs02-11` | RE-CS-02 | `jdcloud,re-cs-02` | `192.168.11.0/24` | `cs02-11.hs.jmsu.top` |
| `ss01-12` | RE-SS-01 | `jdcloud,re-ss-01` | `192.168.12.0/24` | `ss01-12.hs.jmsu.top` |

When adding a router, add a complete row first. The inventory validator must
reject duplicate IDs, duplicate FQDNs, overlapping CIDRs, unknown boards, and
an FQDN whose trailing number does not equal the CIDR's third octet.

## 3. Naming and Headscale reconciliation

The firmware derives a desired name from the active LAN address, after
validating a RFC1918 `/24`–`/30` prefix. WAN DHCP and PPPoE do not participate
in this calculation.

The desired name is supplied to Tailscale on first enrollment. For a retained
sysupgrade or a supported Factory image, the existing `/data` state is loaded
before enrollment. This keeps the existing Headscale node and Tailnet address;
it must never delete the node, log out, force reauthentication, or consume a
new key merely to rename it.

Headscale can retain a legacy MagicDNS `given_name` even after the router has
updated its local Tailscale hostname. Therefore the controller, not the router,
owns existing-node rename reconciliation:

1. find the existing node by its retained Tailnet identity/address;
2. compare its current MagicDNS name with the registry FQDN;
3. rename the same Headscale node only when the target FQDN is unique; and
4. verify the name resolves to that node's Tailnet IP through Quad100.

The router must never carry a Headscale admin API key or gRPC credential. A
controller-local reconciler may use the local `headscale nodes` CLI and must
skip CI/debug/ephemeral nodes and fail closed on ambiguity.

`Scripts/ReconcileHeadscaleFleetIdentity.sh` is that controller-side helper.
Run it first without arguments on the trusted Headscale host to print proposed
renames; run it again with `--apply` only after reviewing the exact node ID,
current name, and advertised LAN CIDR. It calls the controller's local
`headscale nodes rename -i <node-id> <short-id>` command. No OpenWrt gRPC
listener, callback token, or Headscale admin key in the firmware is needed.

An existing legacy `openwrt-...` or `re-...-s<octet>` name is not CD-eligible
until the controller has reconciled it to the registry name. Firmware now
migrates only those generated legacy forms to the LAN-derived short convention;
controller-side rename verification remains a separate required gate.

## 4. Build policy

Pi, CommandCode, Multica, and their extensions have an independent signed
runtime-update path. Do not flash a router solely because one of those runtime
components has updated.

The future nightly candidate workflow must:

1. run only after the agent-runtime release policy has produced a verified
   generation;
2. compare a firmware-input digest (source pins, packages, overlays, runtime
   generation, and device configuration) with the latest successful artifact;
3. skip an identical rebuild; and
4. build each distinct model/configuration once, rather than recompiling the
   same RE-CS-07 image once per LAN CIDR.

The requested maintenance window is local midnight, but GitHub Actions cron
uses UTC. A timezone must be recorded explicitly before any schedule is
enabled; until then, this policy does not authorize a cron trigger.

## 5. Guarded CD gate

`FIRMWARE-FLEET-CD.yml` is `workflow_dispatch` only. Its `DEPLOY` input is
`false` by default; a real flash also enters the `firmware-cd` GitHub
Environment. Configure that Environment with main-only deployment and a
required reviewer before allowing it to hold the deployment secrets.

The manual `PREFLIGHT` route is read-only. It first requires a successful
main-branch build run and then confirms the remote board, active LAN CIDR,
local hostname preference, controller-assigned MagicDNS name, `/data`, WAN,
Tailscale, MagicDNS, and Nikki. A legacy controller name therefore fails
before any artifact is transferred.

When explicitly enabled after preflight, a run handles one device and is
evidence-based. A future nightly orchestrator must dispatch devices in the
approved order rather than trying to combine artifacts from separate build
workflows:

```text
candidate build
  -> artifact metadata + SHA256SUMS validation
  -> resolve registry MagicDNS through the Tailnet
  -> verify board, active LAN CIDR, Tailscale health, /data, and Nikki health
  -> resumable SSH transfer
  -> remote SHA256 + sysupgrade -T
  -> sysupgrade -c
  -> new boot ID + post-boot acceptance
```

Every build artifact also carries `workflow_commit`, which identifies the
GitHub Actions caller-workflow revision independently from `source_commit`
(the pinned upstream OpenWrt source revision). CD requires the artifact's
`workflow_commit` to equal the successful build run's `head_sha`, and accepts
only the per-device build workflow registered for that target. This prevents
an unrelated successful main-branch run or stale artifact metadata from being
treated as the requested candidate.

The RE-SS-01 sysupgrade image is about 447 MiB, close to that 1 GiB device's
default `/tmp` tmpfs limit. Every firmware therefore includes a small startup
hook, but it raises the tmpfs limit to 512 MiB **only** on board
`jdcloud,re-ss-01`; tmpfs allocates RAM on demand, so this is a ceiling rather
than 512 MiB reserved at boot. Before calling `sysupgrade`, the CD helper runs
`openwrt-upgrade-space check` against the image staged under `/data`. It
requires enough current `/tmp` space for the image plus a 48 MiB reserve and at
least 64 MiB of available RAM plus free zram, then requires `sysupgrade -T` to
pass. The space/memory check runs both before and after that image test. Any
missing helper, board mismatch, non-tmpfs `/tmp`, or insufficient capacity
aborts before flashing. The
workflow does not create disk-backed swap; existing zram remains the only
swap layer.

The JSON inventory is the source of truth for each machine's board, LAN CIDR,
MagicDNS FQDN, and matching artifact. Do not copy the full deployment logic
into one workflow per router: that would let safety checks drift. If nightly
per-device schedules are approved later, add thin per-device scheduled
wrappers that call a shared reusable build/deploy workflow with a fixed
inventory ID. Each wrapper must remain opt-in until the maintenance timezone,
staggered rollout order, reviewer approval, and rescue path are recorded.
Today there is no `schedule` trigger and no automatic deployment.

Tailscale identity state is stored at `/data/tailscale/tailscaled.state`, not
`/etc/tailscale/tailscaled.state`. Normal sysupgrade preserves `/data` because
the deployment uses `sysupgrade -c`, while a clean `-n` upgrade or factory
operation may discard configuration or repartition storage. Never infer that
factory installation preserved the old identity: confirm `/data` and its
state file before and after that operation, or explicitly back up the state
through an approved recovery path first. Losing `/data` means a new Tailscale
identity may be enrolled.

The resolver result is a locator, not authority to flash. Before every upgrade,
the deployment job must compare the remote board name and advertised LAN CIDR
against the inventory row and require:

```sh
openwrt-ci-health --require data,wan,tailscale,magicdns,nikki
```

One failure stops the remainder of the fleet. Devices are never flashed in
parallel. The deployment path receives `contents: read` and `actions: read`
only, uses `HEADSCALE_CD_AUTHKEY` scoped to `tag:ci-deploy`, and has no access
to the ordinary build job's secret contract. It requires these additional
Environment secrets, which must use a dedicated deploy key rather than a
personal key:

- `FIRMWARE_CD_SSH_PRIVATE_KEY` — private half of a key whose public half is
  installed through `OPENWRT_DROPBEAR_AUTHORIZED_KEYS`.
- `FIRMWARE_CD_KNOWN_HOSTS` — pinned Dropbear host-key entries for the exact
  registry FQDNs. The CD workflow rejects an unknown or changed host key.

There is intentionally no daily flash schedule yet. Before enabling one,
record the maintenance timezone, approved rollout order, rollback/rescue path,
and a controller-side name reconciliation result for every target.
