# Shared GitHub and CNB firmware builds

## Scope

Both repositories can build the same reviewed profile at the same source commit.
They share `Scripts/firmware_build.py`, the existing reviewed `WRT-CORE.yml`
shell steps, `Config/`, package scripts and overlays. `cnb_replay_core.py` is a
compatibility entrypoint to that same module. Platform entrypoints prepare the
same Debian bookworm build container and checksum-pinned Go/Node host tools.
A native GitHub VM and a CNB runner are not assumed to have identical defaults.

A source/configuration change is committed once and synchronized to both hosts.
Either host can originate that change. Merge divergent changes locally before
synchronizing; neither mirror is allowed to overwrite the other automatically.
Both repositories keep `.github/workflows/` and `.cnb.yml` in the same history.

## Entry points

- GitHub `DUAL-PLATFORM-CHECK.yml`: push/PR/manual, no secret or firmware access.
- GitHub `DUAL-PLATFORM-BUILD.yml`: manual, one profile; `execute_build=false`
  runs only the contract. Set true only after that host's build secrets are ready.
- CNB main and other branch pushes/PRs: contract checks only.
- CNB main: the individual `web_trigger_re_build_*` / `api_trigger_re_build_*`
  events reuse the migration branch's exact YAML entries through anchors.
  Main has no fleet fan-out, deployment, scheduled compilation or devbox event.
- Existing migration branch: historical manual events and report-only schedule
  remain branch-scoped. Its secret-free push also checks the shared contract.

The eight enabled profiles are RE-CS-07, RE-CS-02, RE-SS-01, WLG-RE-CS-07,
CPE-5G B, CPE-5G configuration-only, QCA WIFI-NO and QCA WIFI-YES. The disabled
CPE baseline A stays outside both new build entrypoints. Unsupported runtime
variants do not gain eligibility from this change.

## Configuration and drift checks

Reviewed caller workflows remain the profile input source. Their source pins,
board/config identity and default inputs are checked by
`cnb_re_profile_preflight.py`. `dual_ci_contract.py` compares normalized inputs,
configuration hashes and every selected shell-body hash across both entrypoints.
Changes to the locked core require deliberate review and updating its digest in
the shared compiler; both new entrypoints reject an unreviewed core change.

The existing per-model GitHub workflows remain available. Use the new shared
entrypoint when checking Debian/toolchain parity with CNB; the older native-VM
workflows can have different bootstrap and cache behavior.

```bash
python3 -m pip install -r ci/firmware-requirements.txt
python3 Scripts/dual_ci_contract.py
python3 -m pytest -q tests/test_dual_ci.py tests/test_cnb_replay_core.py tests/test_cnb_re_profile_preflight.py tests/test_cnb_shadow_pipeline.py
```

This local suite executes the orchestration with simulated shell/toolchain
operations and synthetic artifacts. It does not run make, download OpenWrt,
compile firmware, contact a router, sign runtimes or flash a device. It exercises
all 22 build steps, identical plans, mismatched identities, missing credentials,
wrong targets and Git divergence rejection. Real compilation remains a separate
acceptance gate after secrets are complete.

## Credentials and artifact privacy

GitHub and CNB keep their own secret stores. No token or secret value is mirrored
in Git. All admitted build names are centralized in `firmware_secret_gate.py`;
GitHub references those names directly, while CNB imports the existing private
`projects/openwrt-ci/env.build.yml`. Fill equivalent values independently using
each platform's secret UI; do not commit them or send them in chat.

Each host checks required names before heavy dependency setup. Empty/placeholder
required values stop the job; optional missing names are reported without their
values. Passing the minimum gate proves sufficient build inputs, not that every
optional feature or credential matches between hosts. Device enrollment keys
are mandatory only for the reviewed profiles that require them. CNB imports
still require an appropriate allowlist for repo, branch, event and image.

Compilation does not receive repository-write, Headscale CI, signing or flash
credentials. It produces a non-secret `build-receipt.json` bound to the platform,
actual run identity, workflow/source commits, normalized inputs and compiler/core
hashes. The receipt is included in SHA256SUMS and rechecked with the private
artifact inventory. Configuration-only profiles produce no firmware or receipt. The legacy cache
constructor requires a numeric run ID; CNB therefore uses a deterministic
128-bit-derived numeric compatibility key while preserving its real CNB run
ID in the receipt. GitHub retains its real numeric run ID. Legacy shell
branding uses the shared canonical GitHub repository name on both hosts, so
`WRT_MARK` does not change to the CNB organization name; the receipt separately
records the actual executing repository.

Private CNB images remain private commit attachments. Verify their actual
retention separately. A private GitHub repository may retain private firmware
artifacts. The new workflow uploads only the receipt when GitHub is public:
full images with embedded configuration need an explicitly configured private
artifact destination before the ephemeral job ends. No new public release is
created. Receipts and artifact hashes may differ by platform/run; equal input
plans do not assert byte-for-byte reproducibility of OpenWrt images.

## Keep the two repositories aligned

Configure named remotes without embedding tokens in their URLs; use the existing
credential manager or platform-native credentials. For example, use `github`
and `cnb` as remote names, then:

```bash
# Default: inspect only, no remote writes.
python3 Scripts/sync_git_hosts.py --branch main
# After reviewing the plan: ordinary fast-forward pushes to both hosts.
python3 Scripts/sync_git_hosts.py --branch main --apply
# Creating a reviewed test branch on both hosts requires explicit opt-in.
python3 Scripts/sync_git_hosts.py --branch codex/dual-platform-build --apply --allow-create
```

The helper checks both remote branch heads before either push, rejects remote
changes absent locally, uses plain pushes, and verifies the destination commits.
It neither deletes refs nor pushes tags/other branches. Temporary local fetch
refs are cleaned up. The two-host operation is not atomic; partial success is
reported and retried after review, never rolled back with a force push.

For edits originating in either web UI, fetch both branches and merge their
changes in a local reviewed branch before using the helper. Blind bidirectional
force mirrors would lose independent edits or trigger loops. CI contract checks
can run on both copies; actual builds remain manual, so synchronizing a commit
cannot implicitly compile or flash firmware. Secret stores, Actions histories,
CNB histories and retained artifacts need their own backups; Git mirroring
backs up source/configuration history only.

## Promotion

The implementation is a separate test branch based on the existing CNB
migration ref. Both main branches have advanced independently; do not replace
main with this branch or assume it includes their newest CPE/feature changes.
Reconcile those reviewed changes, run the contract again and then promote the
same resulting commit on both hosts. A firmware-input pin change still needs
its normal candidate review. The existing key-rotation gate for historical
CPE/QCA firmware tests remains outstanding until confirmed.

This task authorizes migration compatibility checks, not firmware deployment.
No flash entrypoint is added. The currently deployed Nikki 06:10/06:25/06:40
schedules and router configurations are outside these source-only changes.
