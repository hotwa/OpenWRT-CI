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

The RE-CS-02 and RE-CS-07 test images also include the matching OpenWrt
`kmod-ipvlan` kernel module and the `ipvlan` CNI plugin. This only installs
capability: it does not create an ipvlan network or enable nftables rules at
boot. The default container network remains `host`; bridge+nft and ipvlan-l3
are optional experiments and must be enabled explicitly after device testing.

The staged CNI set intentionally omits the `firewall` and `portmap` plugins.
They can invoke iptables, which conflicts with the device's nftables-owned
fw4/Nikki/Tailscale rules. Bridge mode must use `ipMasq=false` and a scoped
nftables policy instead.

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

Keep Compose files and application volumes below `/data/containers/`. Before
any upgrade, export important application configuration separately. Prefer a
normal `sysupgrade` that preserves the existing data partition; do not use a
factory image or repartitioning procedure when the data must be retained.

For a probe of an already running router, copy `Scripts/ProbeContainerRuntime.sh`
to the router and run it without arguments for inspection. Add `--run` only
when pulling and executing the `alpine` host-network smoke container is
intended; add `--compose` to exercise a temporary host-network Compose service.

## Rollback

If the container runtime is unstable, stop and disable the experimental
service, then flash the ordinary `RE-CS-07-BUILD` artifact with the normal
upgrade path. The ordinary image does not include the test service. Container
data under `/data/containerd` is left untouched so it can be inspected or
removed later after an explicit backup decision.
