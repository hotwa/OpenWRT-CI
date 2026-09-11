# Acceptance checklist

Apply relevant checks to every device after the candidate has booted. “Service process exists” is not enough when a behavior can be exercised safely.

## Identity and persistence

- Candidate commit marker matches the selected artifact.
- `board_name`, target and model match.
- Boot ID changed after the upgrade/reboot.
- `/data` is a real, writable block-backed mount; data-runtime reports persistent mode.
- Expected UCI and user data survived a retained upgrade.

## Network

- LAN address and default route are correct.
- WAN DHCP or PPPoE is established as expected.
- DNS resolution and HTTPS work.
- Tailscale is logged in, the device has its expected identity, accepted/advertised routes are present, and inter-site management paths work.
- Nikki and nft/fw4 are active without unexpected policy conflicts.
- No new persistent route, DFS, firewall, kernel, I/O, filesystem, OOM or crash errors appear in logs.

## Container runtime and Compose

- `containerd-test` is active only when the build gate intentionally includes it.
- `/data` backs containerd state.
- `container-bridge-nft status` succeeds; selected CIDR does not conflict with LAN or Tailnet; required CNI and nft state exists.
- A real Compose fixture uses the external managed network, for example `networks.default.external: true` and `name: bridge`. Do not ask nerdctl to create a Docker-style project bridge when `portmap`/CNI firewall plugins are intentionally absent.
- Test at least one `restart: always` service through a real whole-device reboot without running `compose up` afterward.
- Confirm the same container identity/task returns Up and can reach its bridge gateway; add DNS, inter-service and persistent-volume checks when the fixture provides them.
- When relevant, contrast `always`, `unless-stopped`, manual stop and `compose down` semantics rather than assuming Docker behavior.
- A factory install with empty `/data` has no pre-existing container to restore; record that as not applicable and separately test first deployment.

## Multica and agent runtimes

- Multica daemon authenticates automatically and its intended Pi/OpenCode runtime becomes online.
- Bootstrap reaches its success log and exits its helper; a procd status such as `running (1/2)` may be healthy when the daemon remains and the successful one-shot bootstrap has exited.
- `.agent_state` contains a server-valid Agent ID, current runtime ID, dynamic Agent name, role-card hash and expected safe custom arguments.
- OpenCode-managed Agents use the reviewed unattended argument; Pi-managed Agents use the reviewed yolo-mode arguments.
- The server Agent is active/unarchived and bound to the current runtime. No duplicate Agent was created during the boot.
- If the saved Agent is archived, bootstrap restores the exact ID before updating. If the ID is absent, it may adopt only one structurally managed Agent with the same base and exact LAN CIDR; ambiguity fails closed.
- The generated `/data/multica/openwrt-agent.md` reflects the firmware template and local device facts. Pi, OpenCode and CommandCode role-card links point to it without overwriting administrator-owned files.
- No continuing `bootstrap prerequisites are not ready`, authentication, authorization, backend conflict or runtime launch loop remains.

## Model-specific checks

For this site's current fleet:

- RE-CS-02: `radio0=149/HE80/CN`, `radio1=6/HT20/CN`, `radio2=36/HE80/CN`; radios enabled as intended and no DFS-state error.
- RE-CS-07: wireless configuration remains absent for the NOWIFI build.
- RE-SS-01: apply only its current approved wireless/storage baseline; do not copy RE-CS-02 radio mapping merely because both use IPQ60xx.

## Completion rule

Pass only when every required item has direct post-boot evidence. Document waived or not-applicable checks and why. A failure on any device keeps the loop open unless it is explicitly accepted as a non-blocking limitation by the user.
