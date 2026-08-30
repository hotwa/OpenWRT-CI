# Agent Runtime Signed Release Contract

`Agent-Runtime-Bump.yml` runs at UTC minute 0 every hour. It resolves the
app-layer pins, builds arm64 and x64 musl generation payloads, and probes
CommandCode, Pi and Multica before it can commit or publish anything.
The job only publishes a new release when the verified app-layer pins changed.

The release is an all-or-nothing stack. A router must never run `npm install
latest`, `pnpm update`, or CLI self-update from the Runtime Manager.

## Artifacts

For each architecture the release contains:

- `agent-runtime-<runtime_release>-<arch>-musl.tar.gz`
- its detached `*.manifest.json` and `*.manifest.json.sig`
- one signed `index.json` and `index.json.sig`

The manifest declares the monotonic `runtime_release`, architecture and musl
contract, Node ABI, every component version, lock SHA256,
critical executable SHA256 values, bundle SHA256, and the minimum free-space
requirement. `index.json` lists both architectures and only relative artifact
names; the device resolves them from its configured release base URL.

The manifest is deliberately detached. Including an archive's own SHA256 in
that archive would be a hash cycle. `agent-runtime` verifies the signed
detached manifest and payload before extraction, then writes that exact
manifest to `<generation>/manifest.json`. Consequently the installed
generation root always contains `manifest.json`, without compromising the
bundle hash.

## Signing key contract

The private Ed25519/usign key exists only in GitHub Actions secret
`AGENT_RUNTIME_USIGN_SECRET_KEY`. It is written to a `0600` runner-temporary
file and removed after signing. Do not generate, commit, or store a private key
in this repository.

The matching public key is a normal firmware input at
`/etc/agent-runtime/usign.pub` (repository overlay path
`files/etc/agent-runtime/usign.pub`). A non-dry-run workflow refuses to start
without that file and rejects a secret that does not derive to the same public
key. The public key must be rotated by a firmware release; a runtime update
cannot rotate it. The release base URL is supplied on device by
`/etc/agent-runtime/release-url`.

## Local release checks

The scripts are deliberately split so CI and a maintainer can inspect each
boundary:

```sh
Scripts/build_agent_runtime_generation.sh --arch arm64 --output /tmp/generation-arm64
Scripts/package_agent_runtime_bundle.sh --source /tmp/generation-arm64 --output /tmp/release --arch arm64 --runtime-release 123
Scripts/verify_agent_runtime_bundle.sh --bundle /tmp/release/agent-runtime-123-arm64-musl.tar.gz --manifest /tmp/release/agent-runtime-123-arm64-musl.manifest.json
```

Signing and publication require the actual public key, private secret, and
GitHub credentials; they are not development fallbacks. `tests/test_agent_runtime_release_pipeline.sh`
covers release shape and the explicit missing-secret failure path.
