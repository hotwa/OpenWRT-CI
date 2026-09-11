# Firmware upgrade loop runbook

## 1. Establish the candidate and fleet ledger

Record, without secrets:

- repository, remote, clean worktree, branch and candidate commit SHA;
- caller workflows and their expected device/config matrix;
- device label, management IP, expected `board_name`, image kind and any model-specific checks;
- SSH identity path and an isolated `UserKnownHostsFile` per device;
- current firmware commit, boot ID, board information and `/data` state;
- Action run, artifact name, local checksum, upgrade result and acceptance result.

Site defaults for this repository, subject to current verification:

| Device | Address | Expected board | Workflow |
|---|---|---|---|
| RE-CS-02 | `192.168.11.1` | `jdcloud,re-cs-02` | `RE-Mesh-BUILD.yml` |
| RE-SS-01 | `192.168.12.1` | `jdcloud,re-ss-01` | `RE-Mesh-BUILD.yml` |
| RE-CS-07 | `192.168.10.1` | `jdcloud,re-cs-07` | `RE-CS-07-BUILD.yml` |

The usual maintenance key is selected with `OPENWRT_MAINTAINER_KEY`; this site's current default is `/root/project/OpenWrt-Config-Backup/ops/ssh/openwrt_config_backup_maintainer_ed25519`. Verify that it exists without printing it.

## 2. Build without duplication

1. Confirm the desired commit is pushed to the authorized branch.
2. Inspect recent workflow runs for that exact head SHA.
3. Do not dispatch a second run while an equivalent run is queued or active.
4. Trigger the normal per-model caller workflow, not an obsolete test caller, unless the task explicitly targets the test workflow.
5. Monitor meaningful transitions. Stay quiet while a healthy build is merely running.
6. If CI fails, inspect the failed step and logs. Use the repository's documented CI debug gate when present. Re-run only after fixing a real defect or establishing a transient failure.

## 3. Verify artifacts before transfer

Require all of the following:

- workflow conclusion is successful;
- workflow `headSha` equals the candidate;
- artifact name and metadata identify the expected build config;
- selected filename contains the exact expected device target;
- `SHA256SUMS` validates every downloaded file;
- use `*-sysupgrade.bin` for an installed OpenWrt system and the correct `*-factory.bin` only for a supported first install;
- no artifact from a different matrix job, earlier run, or similarly named model is accepted.

Keep downloads in a candidate-specific directory. Large private artifacts may contain embedded credentials; do not publish, attach, or copy them outside the authorized hosts.

## 4. Device preflight

For each device, sequentially:

1. Read `ubus call system board`, the firmware commit marker, boot ID, disk/mount state and free space.
2. Match `board_name` to the image. A mismatch is a hard stop.
3. Confirm `/data` is a real block-backed mount when the runtime depends on it. A writable directory named `/data` is not enough.
4. Check WAN/LAN routes and at least one management fallback that is already configured, such as Tailscale.
5. Record container and Multica state so post-boot comparisons are possible.
6. Transfer with resumable `rsync` over SSH to a candidate-specific file under a verified spacious filesystem, normally `/data`.
7. Compare the remote SHA-256 with the artifact checksum.
8. Run `sysupgrade -T <exact-image>` and require success before the real upgrade.

Do not flash devices in parallel. Finish reconnect and minimum health checks on one device before starting the next.

## 5. Upgrade and reconnect

For a retained OpenWrt upgrade, run `sysupgrade -c <exact-image>`. The final SSH/ubus connection failure after “Commencing upgrade” is expected and is not itself a failed flash.

Reconnect with bounded polling:

- first expect the old SSH session to disappear;
- poll the LAN address with a short connection timeout;
- accept a changed host key only when the user has authorized this for the exact devices, and keep it in the loop's isolated known-hosts file;
- if LAN does not return, try an already configured Tailscale address or routed peer path;
- do not repeatedly issue `sysupgrade` because SSH is temporarily absent;
- after reconnect, require the new boot ID and candidate commit before continuing.

## 6. Factory and blank `/data` behavior

Factory installation is not equivalent to retained sysupgrade:

- If the installer preserves an existing independent `/data`, the new firmware must reconcile retained runtime and Agent state.
- If `/data` is blank or newly formatted, runtime state, container metadata, images, Compose projects and local sessions start empty. Build-injected private bootstrap inputs may log Multica in and create/recover an Agent, but they cannot recreate user Compose projects that do not exist.
- If factory tooling overwrites the complete eMMC/GPT, assume `/data` can be destroyed unless the tool's verified contract says otherwise.

This repository enables guarded eMMC data provisioning for the three listed workflows. Provisioning may format only a uniquely identified, raw, unmounted and approved data partition on a recognized topology. Ambiguous partitions, unknown filesystems, board mismatch or failed probes must fail closed. Multica and containerd should refuse to place persistent state on the root overlay while `/data` is unavailable.

## 7. Failure feedback

Collect the smallest evidence that distinguishes the layer:

- build: failed step, exact commit, relevant log tail;
- artifact: target/metadata/checksum mismatch;
- boot: board, boot ID, kernel log and mount state;
- network: routes, interfaces, DNS and policy service state;
- container: containerd status, bridge helper status, CNI/nft evidence and container task state;
- Multica: service state, runtime list, safe `.agent_state` fields and stage-specific bootstrap logs.

Never dump UCI sections or JSON files that contain tokens. Filter server responses to non-secret identifiers, names, status, runtime binding and archived state.

When the defect belongs to the repository:

1. Reproduce it with a focused test or safe device probe.
2. Form one falsifiable root-cause hypothesis.
3. Patch the common implementation rather than one device when the behavior is shared.
4. Add a focused regression for the observed failure and its ambiguity/fail-closed boundary.
5. Run syntax checks, focused tests and `git diff --check`.
6. Commit and push the authorized branch.
7. Dispatch only affected normal workflows for the new SHA.
8. Repeat the entire artifact and device loop; a hot-patched device is evidence, not the final firmware result.

## 8. Cleanup and completion

After recording evidence:

- stop and remove only test Compose projects created by this loop;
- remove exact temporary images from devices after a successful boot;
- retain user projects, images, `/data`, credentials, role cards and `.agent_state`;
- retain local artifacts only if the user wants them or they are needed for rollback;
- stop the monitor/heartbeat once all acceptance checks pass.

Report the final candidate SHA, Actions, artifact verification, per-device results, any intentionally retained non-blocking issue, and what temporary material was removed.
