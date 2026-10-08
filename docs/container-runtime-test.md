# RE-SS-01 / RE-CS-02 / RE-CS-07 container runtime test

The experimental workflow is `.github/workflows/RE-CONTAINER-RUNTIME-TEST.yml`.
It is one manual entry point that can build RE-SS-01, RE-CS-02, RE-CS-07, or
all three. Distribution is controlled by `WRT_CONTAINER_RUNTIME_TEST=true`
(reusable-workflow default: `false`), not by the caller workflow's name.
`RE-Mesh-BUILD` and `RE-CS-07-BUILD` already explicitly enable this flag and
continue to do so. A `TEST=false` build must not contain this runtime, its
init/UCI/bridge overlay, or its Docker Hub mirror policy. Do not copy these
files into the unconditional `files/` overlay. Enabling another caller remains
a separate acceptance decision.

The Action downloads the latest stable official `nerdctl-full` arm64 release,
verifies its `SHA256SUMS` entry, and copies only the rootful `containerd`,
`containerd-shim-runc-v2`, `ctr`, `nerdctl`, `runc`, and CNI binaries into the
firmware. BuildKit and rootless helpers are intentionally omitted. `nerdctl
compose` is provided by nerdctl; there is no separate `nerdctl-compose` package.

The default runtime source is `prebuilt`. The reusable workflow also accepts
`auto`, which falls back to the OpenWrt `containerd`/`nerdctl`/`runc` packages
only when the prebuilt download or validation fails. It is not enabled by
default because a silent source fallback would make a build much slower and
less obvious.

The test workflow also exposes an optional `CONTAINER_RUNTIME_VERSION` input.
Leaving it empty follows the latest stable release; setting it to a release
such as `2.3.5` makes a reproducible rollback image from that bundle.

The RE-SS-01, RE-CS-02, and RE-CS-07 test images include the bridge CNI plugin
and a boot-time `bridge+nft` policy. The unsupported `ipvlan-l3` path is
deliberately not included: on the target
kernel its virtual gateway was unreachable before packets reached the host
firewall, so adding the module would only increase firmware size and failure
surface.

The staged CNI set intentionally omits the `firewall` and `portmap` plugins.
They can invoke iptables, which conflicts with the device's nftables-owned
fw4/Nikki/Tailscale rules. Bridge mode must use `ipMasq=false` and a scoped
nftables policy instead.

## Default bridge+nft mode

The image replaces the old iptables-based default CNI configuration with the
default network name `bridge`, backed by the dedicated CNI bridge device
`ctrbr-nft0`. The configuration uses `ipMasq=false` and omits `portmap` and
`firewall`, so it never invokes `iptables-nft` against fw4/Nikki/Tailscale's
nftables tables.

At boot, after `/data` is verified as a real ext4/f2fs block mount,
`container-bridge-nft` chooses a non-overlapping private `/24`, persists the
choice in `/data/containerd/nerdctl/bridge-subnet`, renders the CNI file, and
installs a source-scoped fw4/nftables policy. It enables the firewall policy
but does not create the bridge or start a container; CNI creates
`ctrbr-nft0` when the first bridge-network container starts. The selected
subnet is dynamic so a firmware built with `192.168.11.1` can coexist with
another build using a different LAN range.

The service invokes the same helper automatically. Manual status and recovery
commands are:

```sh
container-bridge-nft status
nerdctl run --network bridge --memory=512m --rm alpine:latest \
  wget -T 15 -O- https://api.ipify.org
container-bridge-nft disable
```

The enable operation reloads only firewall configuration; it does not reload
netifd or Nikki, so it does not intentionally bring down LAN, WAN, or
Tailscale links and does not let netifd own `ctrbr-nft0`. The init service
requires the helper to succeed before starting containerd. Failure to select
a subnet or install CNI/nft/firewall policy, or a missing/non-executable helper,
leaves the daemon inactive by default. Later-stage failures remove generated
CNI/nft files; early failures can leave files from an earlier successful enable.
Do not assume that failure disables attachment or stops existing containers.
Stop bridge-network containers (for example with
`nerdctl compose down`) before manually disabling; the helper does not stop
containers for you.

The active nft policy sends container DNS to Nikki `:1053`, TCP public traffic
to Nikki `:7891`, and marks public UDP with `0x81` for Nikki's TUN route. The
RFC1918, Tailnet, and multicast/reserved destinations remain direct. This
avoids depending on Nikki's dynamically resolved `lan_inbound_interface` set.

Because `portmap` is intentionally absent, do not rely on Docker-style `-p`
publication in this mode. Use the container IP on `ctrbr-nft0` or a reverse
proxy. Use `host` only as the explicit fallback for a service that cannot run
with bridge+nft; host containers share the router's port namespace and must be
audited for WAN exposure.

The bridge policy permits the container zone to LAN, WAN, and Tailnet and
permits LAN/Tailnet return access. Whether a LAN client can reach a container
still depends on the container listening address and the destination port;
there is no blanket WAN ingress rule. The dynamically selected container
subnet is reported by `container-bridge-nft status` and must be used in
diagnostics rather than hard-coded in firewall rules.

### WAN-independent boot recovery and manual escape

The initial subnet is `10.250.0.0/24`; a safe persisted choice is reused.
`ip route get` reporting unreachable is not evidence of a subnet conflict on
its own: a PPPoE default can exist before the link is usable, and with no WAN
route iproute2 can return only `RTNETLINK answers: Network is unreachable` on
stderr. The guard checks all IPv4 route tables before permitting these states.
Overlapping `unreachable`, `blackhole`, `prohibit`, and `throw` prefixes
(including parent prefixes, child prefixes, host routes and explicit negative
defaults) remain conflicts. Local/connected overlaps and routes into
LAN/Tailnet/Nikki/TUN are rejected; the managed bridge's own addresses remain
reusable. Unknown lookup errors or a failed route inventory remain failures.
An established point-to-point PPPoE default need not contain a `via` token.

Every service start runs bridge enable first; the success log is
`default container bridge enabled`. This is boot/start-time recovery, not a
continuous watchdog. No compose daemon, background WAN wait, or boot-time
image pull is added. After a real failure, fix the cause and start
`containerd-test` again so readiness is checked before restart-policy recovery.

`/etc/config/containerd-test` contains this default:

```uci
config containerd-test 'main'
    option run_without_bridge '0'
```

Only the exact value `1` permits an emergency degraded start after bridge
failure or helper absence. It logs `WARNING` that stale CNI may be used and
Nikki network policy is not guaranteed; **no network isolation is promised**.
The operator assumes that risk. Missing/invalid values fail closed. The escape
never bypasses the real `/data` mount, cgroup controller, or binary checks.
Return it to `0` after diagnosis. Do not use it as a normal boot workaround.

### Docker Hub fallback and trust boundary

The gated file `/etc/containerd/certs.d/docker.io/hosts.toml` is:

```toml
server = "https://dockerproxy.net"
capabilities = ["pull", "resolve"]

[host."https://registry-1.docker.io"]
capabilities = ["pull", "resolve"]
```

containerd tries explicit `host` entries first and the root `server` last:
this means **official first, mirror second**, despite the field name `server`.
Root `capabilities` restrict the fallback to pull/resolve too; neither endpoint
here grants push. Do not reverse these fields into a mirror-first policy.
See [registry host ordering](https://github.com/containerd/containerd/blob/main/docs/hosts.md#server-field)
and [the root hostFileConfig/parser](https://github.com/containerd/containerd/blob/v2.1.4/core/remotes/docker/config/hosts.go).

Granting the public mirror `resolve` trusts its mutable tag-to-digest mapping.
This is an explicit TEST-gated opt-in exception to the upstream recommendation
not to trust public mirrors for resolution. Pull-only cannot provide full tag
fallback when the official resolver is unreachable. TLS verification remains
enabled, but does not establish image provenance. Supply-chain-sensitive users
should replace this policy with a trusted private source or delete the file to
restore Docker Hub defaults; use independently verified pinned digests where
appropriate. Only `docker.io` is affected, not `ghcr.io` or other registries.
Mirror availability is not guaranteed by firmware installation.

The minimal version-3 `containerd-test.toml` stays unchanged: no top-level
`[registry]` section. nerdctl reads the registry hosts configuration; changing
that file does not require restarting the daemon. Pull the required images
during deployment/change management, not during every reboot.

## Data safety contract

The test service uses `/data/containerd/root` as containerd's mutable root and
`/data/containerd/nerdctl` for nerdctl's persistent metadata. Its
init script refuses to start unless `/data` is a real `/dev/*` ext4 or f2fs
mount. This prevents a missing data disk from silently filling the small
firmware overlay.

The containerd state directory and socket remain under `/run/containerd`, so
they are recreated on every boot and no stale socket is preserved on the data
disk. The service also sets an explicit PATH containing `/usr/sbin` and
`/usr/bin`; it does not create duplicate `/usr/local/bin` symlinks.

The existing eMMC data flow mounts the approved data partition by filesystem
UUID. A healthy `LABEL=openwrt-data` partition is preserved; the provisioning
script only formats a strictly verified new or approved raw partition. A
factory flashing tool that repartitions the entire eMMC is outside this
contract and can still destroy `/data`.

Keep every application under `/data/compose/<service>/compose.yaml`, with
relative bind mounts stored below that service directory. Use the external
default network so Compose does not create an iptables-managed project bridge:

```yaml
services:
  app:
    image: alpine:latest
    restart: always
    command: ["sh", "-c", "sleep infinity"]
    networks: [default]
    volumes:
      - ./data:/var/lib/app
networks:
  default:
    external: true
    name: bridge
```

For long-lived services, use `restart: always` with the external `bridge`
network. The supplied RE-CS-02 validation reports that containerd's restart
plugin restores these containers (including CNI) after daemon restart/boot;
there is no separate `compose-apps` init service. Explicitly stopped containers
must not be unintentionally restarted; include that case in on-device
acceptance for the shipped nerdctl/containerd version. A missing local image or
an incompatible existing application configuration is not repaired by this
firmware change.

Before any upgrade, export important application configuration separately.
Prefer a normal `sysupgrade` that preserves the existing data partition; do
not use a factory image or repartitioning procedure when the data must be
retained.

For a probe of an already running router, copy `Scripts/ProbeContainerRuntime.sh`
to the router and run it without arguments for inspection. Add `--run` to
exercise the default bridge+nft network and `--compose` to exercise a Compose
service. The health gate must confirm DNS, Google HTTPS, ChatGPT trace,
`api.ipify.org`, and Nikki/nft counter activity. If bridge+nft fails, remove
only that test's containers/networks, record the reason, and retry the service
with `--network host` as the last-resort fallback.

## Rollback

If the container runtime is unstable, stop and disable the experimental
service. To remove it from firmware, use a verified `TEST=false` artifact with
the normal upgrade path, checking preserved overlay files as well: a retained
sysupgrade overlay can still contain old configs. `RE-CS-07-BUILD` is NOT a
runtime-free rollback image because it explicitly sets `TEST=true`. Container
data under `/data/containerd` is left untouched; do not delete it as part of a
runtime rollback. Back up application configuration before any removal decision.

## Acceptance: boot recovery and registry fallback

Local regression checks (no router changes, pulls or firmware compilation):

```sh
bash tests/test_container_bridge_nft_subnet.sh
bash tests/test_container_bridge_nft_enable.sh
bash tests/test_container_bridge_nft_kernel.sh
bash tests/test_containerd_test_init.sh
bash tests/test_container_runtime_gate.sh
bash tests/test_re_cs_07_container_runtime.sh
```

The kernel test uses an anonymous network namespace and skips explicitly when
that facility is unavailable. The staging test executes the existing workflow
conditionals against isolated fixture trees with a fetch stub; it is not an
artifact inspection or a real registry-failover test. CI discovers these via
the existing `tests/test_*.sh` loop; no workflow entry changes are required.

| Gate | On-device / artifact evidence required |
| --- | --- |
| T1 | `sh -n` for helper/init; init, UCI, hosts.toml and both CNI/nft templates present; `/etc/init.d/compose-apps` absent. |
| T2 | With DHCP before/after a lease and PPPoE before/after link establishment, boot succeeds; success log, generated CNI/nft and containerd socket exist. Reboot/slow-WAN tests require local rescue and a maintenance window. |
| T3 | Without `compose up` after reboot, previously deployed `restart: always` services return Up on external `bridge`; explicitly stopped services stay stopped. Check the persisted selected subnet, not an assumed constant. |
| T4 | Scoped container nft rules/counters exist; container DNS/HTTPS reaches the intended Nikki path. An expected registry HTTP 401 proves reachability, not successful image download. |
| T5 | Record shipped runtime versions and client request traces. First prove official-first with both sources healthy. In an isolated test environment, make official registry/auth endpoints unreachable and pull a tag requiring fresh resolution (for example `alpine:3.21`), proving mirror resolve and pull succeed. Verify pull-only fails at resolution in the same outage. Use fresh test metadata/content and traces so cache hits cannot count as fallback. Restore all temporary test settings. Single-mirror success alone is insufficient. Do not disrupt a live router's WAN/DNS/firewall to run this remotely. |
| T6 | No unknown TOML key/registry warnings on daemon startup or client pull. |
| T7 | In a disposable test environment, inject real subnet conflict and CNI/nft/UCI/firewall/helper failures: default/invalid UCI leaves daemon inactive. Explicit `1` starts with the risk WARNING; stale CNI is allowed to remain, not claimed isolated. `/data`, cgroup and missing-binary failures still refuse startup. Restore `0` afterward. |
| T8 | Inspect fresh TEST=false and TEST=true rootfs artifacts and package manifests. Runtime binaries, helper/init/UCI/templates and docker.io hosts policy are absent from false and present in true. Preserve the current RE-Mesh/RE-CS-07 explicit true callers. A preserved runtime overlay on an upgraded device is not evidence that a false artifact contains it. |

The 2026-09-09 user-supplied device report and read-only RE-CS-02 inspection
establish the starting implementation, not acceptance of this repository patch.
New firmware cold-boot tests and genuine two-source fallback (T2–T5), failure
injection (T7) and generated-artifact isolation (T8) remain release gates until
their own results are recorded.
