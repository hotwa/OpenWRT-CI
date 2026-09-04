# RE-CS-02 / RE-CS-07 container runtime test

The experimental workflow is `.github/workflows/RE-CONTAINER-RUNTIME-TEST.yml`.
It is one manual entry point that can build RE-CS-02, RE-CS-07, or both. It is
intentionally separate from the normal production workflows, so the container
runtime can be retired by removing this workflow and its overlay without
changing the normal firmware path or RE-SS-01.

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

The RE-CS-02 and RE-CS-07 test images include the bridge CNI plugin and a
boot-time `bridge+nft` policy. RE-SS-01 does not include this runtime. The
unsupported `ipvlan-l3` path is deliberately not included: on the target
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
Tailscale links and does not let netifd own `ctrbr-nft0`. If firewall reload or
subnet selection fails, the helper removes the generated CNI/nft policy and
does not start containerd. Stop bridge-network containers (for example with
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
    command: ["sh", "-c", "sleep infinity"]
    networks: [default]
    volumes:
      - ./data:/var/lib/app
networks:
  default:
    external: true
    name: bridge
```

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
service, then flash the ordinary `RE-CS-07-BUILD` artifact with the normal
upgrade path. The ordinary image does not include the test service. Container
data under `/data/containerd` is left untouched so it can be inspected or
removed later after an explicit backup decision.
