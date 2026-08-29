# AGENTS.md

## Upstream merge policy

- Read `docs/upstream-merge-policy.md` before comparing, cherry-picking, merging, or manually copying changes from `davidtall/DaeWRT-CI`, `davidtall/immortalwrt`, `VIKINGYFY/immortalwrt`, or other OpenWrt CI upstreams.
- Prefer small, documented, atomic upstream absorptions. Do not accept upstream deletions of hotwa device targets, Nikki, wrtbak/private build wiring, CPE-5G baselines, Headscale/Tailscale overlays, Node.js 24/Python 3.12 AI agent runtimes, or repository guard tests unless the user explicitly asks for that exact removal.

## Edge AI Agent ecosystem and runtime (Multica / OpenCode / Pi / Hermes)

- **Primary Workflow**: Multica orchestration + OpenCode / Pi CLI agents for autonomous OpenWrt network inspection, firewall telemetry, and self-healing.
- Preserve `Scripts/fetch_node_runtime.sh` (Node.js 24 LTS musl static), `Scripts/fetch_uv_runtime.sh` (`uv` + the offline CPython 3.11/3.12/3.13 build mirror), `Scripts/build_hermes_core.sh`, and baseline finalization in `WRT-CORE.yml`.
- Preserve pre-installed CLI tools and extensions:
  - `opencode-ai` (`opencode` CLI) + `@tarquinen/opencode-dcp`, `@mohak34/opencode-notifier`, `opencode-conductor-plugin`
  - `@earendil-works/pi-coding-agent` (`pi` CLI) + `@aaronkyriesenbach/pi-package-manager`, `btw-pi`, `pi-plan-mode`, `pi-web-search`, `pi-wechat-assistant`
  - Nous Research `hermes-agent` (`hermes` CLI)
  - `luci-app-openclaw` (WeChat/TG gateway and LuCI manager)
- Preserve `/etc/profile.d/20-node-agent.sh` and `/etc/profile.d/30-agent-update-check.sh` (24h non-blocking SSH login status banner and signed-generation guidance).
- Keep `homeproxy`, `daed`, and `dae` pruned from `Config/GENERAL.txt` in favor of Nikki to prevent multi-proxy conflicts and save rootfs space.
- Read `docs/agent-runtime-version-policy.md` before changing any agent-runtime version pin. Layered policy: the app layer (opencode, pi, hermes, their extensions, pnpm, Multica) is checked hourly by `Agent-Runtime-Bump.yml` + `Scripts/bump_agent_runtime.sh`; it commits to `main` only after complete arm64/x64 musl generations have passed probes, repository guards, and signed release publication. Do not treat those CI probes as a device gate.
- Never let automation float the runtime base: `NODE_DEFAULT_VERSION`/`NODE_FALLBACK_VERSION`, `UV_VERSION` and its SHA256s, `PYTHON_RELEASE_TAG`, `PYTHON_SERIES`, and the per-device `WRT_COMMIT` pins stay exact and human-edited only.
- Do not remove CPython 3.11 from `PYTHON_SERIES` or drop the bridge/Core Python-series check in `write_agent_runtime_policy()`. Hermes Core uses the locally mirrored 3.11 during its offline build, then removes only that manifest-verified archive so the Core venv is the sole shipped copy; keep the `WRT-CORE.yml` order uv → node → multica.
- `/data/node` is an `agent-runtime`-managed compatibility symlink to the active signed immutable generation, not a writable global npm/pnpm prefix; do not replace it or run in-place package updates there. `/etc/profile.d/20-node-agent.sh` resolves the active generation for shells, and procd services (`multica`, `hermes-runtime`) must set their own `PATH` because procd never loads `profile.d`. Hermes is a baked Core-only offline runtime: its boot coordinator performs health checks only and must never provision through the network.

## Tailscale LAN Gateway and Route Acceptance

- Preserve `files/etc/config/tailscale` default options: `tailscale.lan_to_tailnet.enabled='1'` and `tailscale.settings.accept_routes='1'`.
- This ensures LAN clients can reach remote Tailnet subnets (`192.168.8.x`, `192.168.9.x`) and MagicDNS (`.hs.jmsu.top`, `.ts.net`) out of the box.
- Maintain top-level DIRECT prepend rules in `nikki-sub-merge` (`100.64.0.0/10`, `192.168.0.0/16`, `hs.jmsu.top`, `ts.net`) so Fake-IP does not hijack Tailnet traffic.


## Headscale auto-enroll

- Read `docs/headscale-auto-enroll.md` before changing the Tailscale or Headscale first-boot path.
- Do not commit a real Headscale auth key, GitHub token, Tailscale state file, or private SSH key.
- The firmware overlay may contain `/etc/config/headscale_auto_enroll`, but it must remain disabled by default unless a private CI build injects a secret at build time.
- Keep `accept_dns=0` by default. DNS control belongs to dnsmasq, mosdns, Nikki, or DAE.
- Keep `accept_routes=0` by default. Route acceptance can conflict with WireGuard, DAE, Nikki, or WAN policy routing.
- Tailscale SSH does not require replacing Dropbear or installing OpenSSH server. Keep Dropbear key-based SSH as the LAN/rescue path.
- Dropbear over Tailscale is provided by `/etc/uci-defaults/90-tailscale-dropbear-access`: do not bind Dropbear only to `br-lan`, do not create `network.tailscale`, and keep fw4 using `device 'tailscale0'` with input accepted and forwarding rejected.
- `headscale-auto-enroll` must apply `tailscale set --ssh=true` for already-enrolled nodes when `headscale_auto_enroll.main.ssh=1`; otherwise LuCI-enrolled or previously enrolled routers can remain at `RunSSH=false`.
- When wrtbak firstboot restore is enabled, preserve the wrtbak recovery gate: Headscale must not consume an auth key until restore reaches a terminal decision, and must reload a restored Tailscale state first.
- For router auth keys, prefer Headscale preauth keys scoped to the 5 standard mesh tags (`tag:openwrt`, `tag:service-host`, `tag:subnet-router`, `tag:ssh-target`, `tag:peer-relay-client`) as documented in `docs/tailnet-mesh-multi-site.md`. Router firmware automatically advertises its LAN subnet (`192.168.x.0/24`) and accepts peer routes by default.

## CPE-5G verified firmware baseline

- The current production CPE feature baseline is controlled build B at 2026-07-06 `VIKINGYFY/immortalwrt@0bad892975fe49fd180f99b414a7f168bb694dd7`, Linux `6.18.37`, `IPQ60XX-706-NOWIFI`. On 2026-07-12 both A and B booted successfully on RE-SS-01; B also exposed `usb0=192.168.66.2/24` and reached `192.168.66.1:6677` from OpenWrt.
- Retain 2026-06-25 `42a1f64b5dbd2a99d05daca94ae5a87eebff59b4` / Linux `6.18.35` as the historical known-bootable fallback. 回退源码时不得撤销无关 hotwa 功能提交。
- Keep `.github/workflows/CPE-5G.yml` pinned to the full 40-character preferred SHA and preserve exact fetch, detached checkout and SHA mismatch failure.
- `davidtall/immortalwrt:stable` is a candidate upstream only, never an automatic production baseline.
- Controlled NOWIFI A remains the no-feature-overlay isolation baseline; B is promoted for CPE use. WiFi-YES still requires a separate real-device gate.
- Normal CPE-5G dispatches must leave `BUILD_BASELINE_A=false` and build only B. Enable A only to isolate source/kernel/NSS boot failures from the CPE/Lucky/Tailscale/Headscale/wrtbak overlay; do not promote A as the daily firmware.
- mwan3 is a CPE-5G B-only package and overlay. Keep Ethernet `wan` primary and `5G`/usb0 backup, preserve the explicit CPE/LAN bypass rules, and run the post-wrtbak managed reconcile. Do not enable mwan3 in `Config/GENERAL.txt`, CPE A, or ordinary QCA workflows.
- Never perform a real WAN-loss test remotely without an independent local/serial/UBoot rescue path and a timed rollback. Existing sessions do not migrate across mwan3 failover; validate new connections plus Lucky usb0 return symmetry, Nikki marks, Tailnet, and SIM probe counters.
- For public services, prefer CPE IPv6 port relay to a Lucky listener on OpenWrt `192.168.66.2`, then reverse proxy only approved `192.168.13.x` services. Do not expose the whole LAN.
- Treat DHCPv6-PD/RA/NDP proxy as experimental until the cellular carrier is proven to delegate a prefix. A single CPE `/64` address is not proof of PD support.
- Treat `davidtall/immortalwrt:stable` as a candidate upstream, not an automatically trusted production baseline. A moving branch name is never sufficient evidence of the source used for a firmware artifact.
- Any change to Linux kernel, qca-nss, qca-nss-dp, qca-nss-drv, qca-nss-ecm, qca-ssdk, Qualcommax kernel patches, RE-SS-01 DTB, factory pipeline, or the firmware source commit must update the baseline table in `README.md`.
- Before promoting a candidate, record the exact source SHA and Action/artifact SHA256, then complete RE-SS-01 实机验证: successful flash, LAN/WAN and NSS checks, two soft reboots, one cold boot, and the CPE `192.168.66.1:6677` management path.
- If an upstream candidate fails to boot or regresses Ethernet/NSS/factory behavior, 回退 only the CPE firmware source pin to the last verified complete SHA. Do not revert unrelated hotwa CPE, Lucky, Tailscale/Headscale, wrtbak, or network feature commits.

## Development and Subagent Test Policy

- **Targeted verification first**: During active development or subagent execution, do not unconditionally run the full 85+ test suite (`tests/test_*.sh`) in loops. Full-suite execution contains heavy sleep mocks, geodata download fixtures, and mount simulations that cause unnecessary delays.
- **Focused module tests**: Subagents must only run tests directly relevant to their modified files (e.g. `bash tests/test_agent_runtime_manager.sh` or `bash tests/test_pi_plan_mode_vendor.sh`), which execute in 1-2 seconds.
- **Full-suite fixture/mock simulation is optional during iteration**: Full-suite fixture/mock runs are optional during subagent development and should be reserved for final pre-commit verification or delegated to GitHub Actions CI (`WRT-CORE.yml` smoke tests). Subagents should skip full-suite fixture/mock runs to prevent timeouts.

## CI string / quoting pitfalls (2026-08-29 RE-SS-01 debug-gate runs)

These three bugs each cost a full failed CI run. Check for them when editing
`WRT-CORE.yml`, `Scripts/*.sh`, or any GHA step:

- **GHA expressions are not bash expansions.** `${{ steps.x.outcome }}` is
  substituted by the runner before the shell runs. Writing bash-default
  syntax `${steps.x.outcome:-}` inside `run:` makes bash hit a dot in a
  parameter name and abort the whole step with `bad substitution`.
  Always emit `${{ steps.x.outcome }}` (or use an `env:` entry) for step
  results; `${VAR:-default}` is only for real shell variables.
- **`IFS='\t'` is two characters (backslash + t), not a tab.** Bash does not
  interpret escape sequences in plain quotes; tab-separated rows then split on
  every `t` and `\`, corrupting fields silently (no `die` message). Use
  `IFS=$'\t'` (ANSI-C quoting) or a `read -d ''`/awk-based parse. See
  `Scripts/build_hermes_core.sh` mirror-row parsing and commit `29afaa9`.
- **`set -e` + command substitution swallows failures silently.** A failing
  `var="$(cmd)"` (e.g. a qemu `target_exec` that cannot load the target
  binary) exits the script with code 1 and prints nothing; the CI log ends
  with only `##[error]Process completed with exit code 1.` after the last
  successful log line. `Scripts/build_hermes_core.sh` now carries an ERR trap
  printing the failing `LINENO` and `BASH_COMMAND`; when adding new
  verification gates, wrap bare `$( ... )` calls in `|| die "..."` with the
  context message instead of relying on `set -e`.

## CI Debug Gate — SSH into a held runner (SOP)

Trigger: dispatch `RE-SS-01-BUILD` (or any caller workflow) with
`DEBUG_SSH: true`, or any `Custom Packages and Agent Runtimes` /
`Compile Firmware` failure. The gate enrolls the runner as ephemeral node
`ci-debug-<run_id>-<attempt>` (`tag:ci-debug`) and holds it up to 90 minutes.

1. Watch the Actions log for `Enrolled: ci-debug-... / 100.64.0.x (ssh user: runner)`.
   If you instead see `WARN: Tailscale debug gate setup failed`, the runner was
   NOT held — the job already finished, so read the failure above that line.
2. From any tailnet host with `tag:ssh-admin` (e.g. local WSL / Antigravity
   agent), connect via the ECS gateway container:
   `ssh -o "ProxyCommand=ssh -i <ECS key> root@112.124.106.23 docker exec -i tailscale-gw nc %h %p" runner@100.64.0.x`
3. Run the environment probe first:
   `ssh runner@100.64.0.x "bash $GITHUB_WORKSPACE/Scripts/ci-debug-probe.sh"`
   (disk, binfmt/QEMU, staging_dir symlinks, musl loaders, node/uv paths).
4. Reproduce the failing package in isolation:
   `cd $GITHUB_WORKSPACE/wrt && make package/feeds/custom/<pkg>/compile V=s -j1`
5. Write the fix locally in this repo, commit, push; then release the runner:
   `ssh runner@100.64.0.x "touch /tmp/continue-ci"`
   and re-trigger the build.

LAN jump path: use `ssh root@192.168.11.1`, then `tailscale status`,
`tailscale ping 100.64.0.x`, and `ssh runner@100.64.0.x`. Headscale ACLs must
permit the OpenWrt admin node to reach `tag:ci-debug` as `runner`. The old
Actions run cannot be resumed; manual held-runner verification must be
followed by a fresh Action run. See `docs/ci-debug-gate.md` for the full SOP.

Secrets (GitHub repo `hotwa/OpenWRT-CI`): `HEADSCALE_CI_AUTHKEY`
(30-year reusable ephemeral preauthkey `tag:ci-debug`), `HEADSCALE_URL`
(`https://headscale.jmsu.top`). DERP map is single-region WuHan (900);
US-hosted runners reach it over DERP relay, expect ~150 ms.

Debug-gate contract: the CI preauth key must already own `tag:ci-debug` and
`ephemeral=true`; `Scripts/setup_ci_tailscale.sh` must not pass a redundant
`--advertise-tags` request. If Headscale reports `requested tags ... are invalid
or not permitted`, enrollment failed before a runner address exists, so do not
attempt SSH. If repository smoke tests report a real-looking auth key, inspect
test fixtures for contiguous `hskey-auth-*` literals and split adjacent shell
strings before changing the scanner.

Dedicated SSH smoke: `.github/workflows/CI-DEBUG-SSH-TEST.yml` provides a
build-free `workflow_dispatch` check with a 30-minute default hold (1-90
minutes). It requires `HEADSCALE_CI_AUTHKEY` and `HEADSCALE_URL`, prints the
`ci-debug-<run_id>-<attempt>` IP/hostname and SSH examples, and releases on
remote `touch /tmp/continue-ci` or timeout. It is concurrency-limited to one
smoke runner and cleans `CI_TSCALE_PID` plus temporary state on every exit.
