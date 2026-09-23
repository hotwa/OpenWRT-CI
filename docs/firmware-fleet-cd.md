# OpenWrt Fleet Identity and Future CD Policy

This document is the authoritative **planned** fleet registry and deployment
contract. It records identifiers and safety boundaries only; it contains no
Headscale API key, SSH private key, subscription URL, or other secret.

The repository does not currently enable unattended firmware deployment. A
daily candidate build and a real device deployment are deliberately separate
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

An existing legacy `openwrt-...` name is not CD-eligible until the controller
has reconciled it to the registry name. The current firmware's historical
`re-cs-02-s11` convention is also transitional; no automatic deployment may
assume it equals the short registry convention until this migration is
implemented and verified.

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

## 5. Future CD gate

When explicitly enabled, deployment is sequential and evidence-based:

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

The resolver result is a locator, not authority to flash. Before every upgrade,
the deployment job must compare the remote board name and advertised LAN CIDR
against the inventory row and require:

```sh
openwrt-ci-health --require data,wan,tailscale,magicdns,nikki
```

One failure stops the remainder of the fleet. Devices are never flashed in
parallel. The deployment path must use a dedicated, scoped runner/credential
inside the Tailnet, separate from ordinary build permissions, and real CD must
remain disabled by default until a maintenance window, rollback path, and
per-device rollout order are approved.
