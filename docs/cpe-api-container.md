# CPE B CLIProxyAPI container

CPE-5G B explicitly opts into the existing container runtime overlay using
`WRT_CONTAINER_RUNTIME_TEST=true`, `prebuilt`, version `2.4.1`, and
`WRT_CPE_API_GATEWAY=true`. A and ordinary callers remain unchanged. The
application does not change source, kernel or NSS pins, registry fallback,
bridge policy, or the Node agent runtime. See [the complete runtime gate
contract](container-runtime-test.md); these device/artifact gates still apply.

The image is the official CLIProxyAPI stable **v8.0.13**, with an independently
resolved Linux arm64 manifest digest
`sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d`.
The verified index digest is
`sha256:6ce96259e6a2fec3b1093301d2dc61989260a8d682465be53e8f70656c6b6784`;
the launcher accepts only the arm64 manifest, not an arbitrary digest. Tags, `latest`, arbitrary
registries/repositories, and malformed digests are refused. Firmware staging
ships public application code, a UCI enable setting and the verified official
ARM64 OCI archive at `/usr/share/cpe-api/cli-proxy-api-v8.0.13-arm64.oci.tar`. It contains no
OAuth state, provider keys, client keys or management keys.

## Persistence and first deployment

The application uses `/data/compose/cpe-api/compose.yaml`, `config.yaml`,
`credentials.json`, `image`, `auth/` and `logs/`. A real `/dev/*` ext4/f2fs mount
at `/data` is mandatory before any staging or launch. Existing application
files must be regular root-owned files with mode 0600; application directories
are root-owned mode 0700. Configuration, credentials and OAuth login state are
never replaced by firmware or ordinary boot. Existing compose/image changes
require an explicit operator migration; they are not silently reconciled.

`credentials.json` holds separate cryptographically random 256-bit client and
management keys. This is local persistent secret material. The launcher prints
no keys, auth files, config dumps or command stderr. The configuration file is
writable because CPA hashes a plaintext management key during startup; the
original usable management key remains in the private credentials file.

Verify the pinned official v8.0.13 Linux arm64 manifest before deployment,
then import that exact image during the deployment window. Prefer a trusted
host fetching and transferring the offline image to avoid using SIM quota;
containerd root/image content is persistent on `/data/containerd`. The root
operator uses the resulting pinned reference (represented by `<pinned-image>`
below; its complete value is
`docker.io/eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d`):

```sh
nerdctl --address /run/containerd/containerd.sock --namespace default load -i /path/to/verified-image.tar
cpe-api prepare '<pinned-image>'
cpe-api start
cpe-api status
```

First firmware boot prepares the baked fixed image pin and missing application
material on the verified data mount without any download. An existing
different pin or administrator disable is preserved and refuses recovery.
Manual `prepare` accepts the same fixed pin and generates only missing
application material. Start verifies that the
image already exists locally; Compose additionally uses `--pull never`.
Neither boot nor service recovery pulls images. If the pinned image is absent,
boot/start checks that the runtime is healthy and loads only the fixed ROM
archive, which must be a regular root-owned, single-link file without group or
other write access. It then verifies the exact image reference is present.
The inspect result must report Linux arm64 and the fixed manifest in
`RepoDigests` (image `Id` is a separate config digest). An existing mismatched
image is refused instead of overwritten. Existing local images are never
reloaded. A missing/unsafe archive safely
defers; there is no registry fallback or SIM download. Offline import has a
120-second bound inside the procd task. The service starts after the
existing `containerd-test` service and waits for its socket for at most 60
seconds in a procd process. Missing mount/runtime/image or unsafe existing
configuration defers startup with a generic message and no infinite retry.
After fixing the cause, use `cpe-api start`. It never starts another containerd
daemon, changes netifd, formats `/data`, or performs a router reboot.

## Listener and resource boundaries

This application explicitly uses the runtime contract's **host networking
fallback**: Lucky needs a stable local backend at `127.0.0.1:8317`; the managed
bridge address is dynamically selected, and the runtime intentionally excludes
portmap. CPA must bind **127.0.0.1**, never `0.0.0.0`, an IPv6 wildcard, or WAN.
The default bridge+nft readiness gate is still enforced by containerd-test;
this application does not enable `run_without_bridge` or relax that gate.
Host networking shares the router network namespace. Any future change away
from the loopback bind requires a new exposure review and device verification.
Direct LAN/Tailnet client access is provided by the separately managed reverse
proxy listener/policy, never by widening CPA's bind.

The Compose limit is 192 MiB, 0.5 CPU and 128 PIDs. `restart: always` handles
process failure and runtime restoration. Boot never issues `start` against an
existing container. Before using an existing container, the manager verifies
its exact image reference and creation-time top-level manifest `Image` digest,
managed label, host network, actual `Path`/`Args` execution,
optional command/entrypoint metadata, 192 MiB /
0.5 CPU / 128 PID limits, nonprivileged execution, no extra capabilities/devices,
and exactly the three approved read/write bind mounts. The nerdctl 2.4.1
Docker-compatible inspect schema reports CPU as `CpuQuota`/`CpuPeriod`; both
must be positive integers and `quota × 2 = period` (normally 50000/100000).
Optional Nano CPU fields must agree if present. `Config.Cmd` is not required
because nerdctl derives actual execution into top-level `Path`/`Args`. These
fields and mount/security conversion are verified against the [fixed nerdctl
2.4.1 implementation](https://github.com/containerd/nerdctl/blob/v2.4.1/pkg/inspecttypes/dockercompat/dockercompat.go).
An explicit `cpe-api stop` (or `disable`) writes a persistent disabled marker,
sets `cpe_api.main.enabled=0`, and stops the container. `cpe-api start` explicitly
restores operator authorization. Ordinary init stop/restart/shutdown does not
change that authorization. A direct `nerdctl stop cpe-api` retains the runtime's
own stopped state, which the app boot hook leaves alone; the shipped runtime's
actual restart-plugin behavior must still pass the device acceptance gate.

## Fixed v8 configuration and later OAuth

The schema is taken from the [v8.0.13 configuration
example](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.13/config.example.yaml),
not the current main branch or legacy v6 examples. It uses `server.host/port`,
`access.api-keys`, `oauth.auth-dir`, `management.secret-key`,
`observability.logs`, `observability.pprof`, and
`requests.streaming.keepalive-seconds`. Auth files map to
`/root/.cli-proxy-api` inside the container. Management remains loopback-only,
key-required, and the built-in panel and its asset downloads are disabled.
Debug/request logging and usage statistics are disabled; rotating log budget
is 8 MiB with at most two error logs. pprof and dynamic plugins are disabled;
SSE heartbeat is 15 seconds.

The manager validates scalar mappings and normal block provider lists before
launch. Separate list items may repeat names/base URLs/model fields; duplicate
keys inside one mapping remain refused. It rejects aliases/tags/multiple
documents and legacy security fields,
and requires the protected listener/auth/profile paths. It preserves an
existing config instead of overwriting it to make it pass. Complex hand-edited YAML (for example flow maps or block scalars) or
unsupported provider configuration requires operator migration of the
validator; refusal is deliberate. The normal OAuth login flow stores provider
credentials in the mounted auth directory and needs no template mutation.
Do not put OAuth state or `credentials.json` into public firmware or Git.

After deployment the operator can run the fixed CPA binary's no-browser OAuth
flow in the existing container, using its mounted config, and handle the OAuth
callback through an authorized local SSH tunnel. Inspect the pinned binary's
`-help` for the provider-specific flags before login. This change performs no
OAuth login and migrates no Windows/Linux CPA provider credentials. Before
login an authenticated `/v1/models` may return 200 with an empty model list:
that proves the listener and client authentication only, not usable inference.
Unauthenticated model/inference requests must fail authentication.

`keep.d/cpe-api` preserves the init and UCI option across normal sysupgrade;
application data lives on the existing eMMC mount. Preserve that data partition
and export config/auth/credentials separately before an upgrade. A factory
repartition is outside this contract. Disabled UCI state, the disabled marker,
existing config and OAuth files must survive the normal recovery path.

## Focused verification and device gates

Run `bash tests/test_cpe_api_gateway.sh` for syntax, B-only caller/gating,
strict image input, real mount checks, config safety, file permissions,
symlink refusal, preservation of existing keys/auth and compose drift refusal.
The tests use isolated local fixtures, never the router or a registry.

Device acceptance must record the exact image digest and runtime versions,
loopback bind/closed WAN exposure, unauthenticated 401, authenticated models
200 (empty before login), cgroup memory/CPU/PID limits, Lucky streaming path,
existing OAuth preservation, and safe missing-image/missing-mount behavior.
Perform planned reboot and explicit-stop recovery only with the authorized
maintenance/rescue procedure. Confirm ordinary reboot restores a running
application, an explicitly disabled app stays stopped, and `nerdctl stop`
remains respected. No real restart, cold-boot or inference result is claimed
by the local fixture tests.
