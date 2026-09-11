---
name: openwrt-firmware-upgrade-loop
description: Run a guarded OpenWrt firmware build, artifact verification, sequential device upgrade, post-boot acceptance, and repository repair loop. Use for one or more real routers when failures must feed back into CI until every approved target passes; do not use for ordinary package installation or an unapproved destructive flash.
---

# OpenWrt Firmware Upgrade Loop

Drive the fleet to one evidence-backed firmware candidate. A successful Action or a reachable SSH prompt is not completion by itself.

## Before changing anything

- Resolve the repository, branch, workflows, target devices, management addresses, expected board names, upgrade method, maintenance authorization, and recovery routes from current evidence. Treat values in the references as site defaults, not universal facts.
- Preserve unrelated work in dirty trees. Prefer a clean worktree for fixes and commits.
- Never expose build secrets, Multica tokens, role-card contents, private keys, Wi-Fi passwords, or full private configuration in logs or reports.
- A prior authorization to iterate permits only the named repositories and devices. It does not authorize repartitioning, formatting ambiguous storage, clearing `/data`, deleting backend Agents, or force-pushing.

## Choose the operation

- For CI through fleet acceptance, read [references/loop-runbook.md](references/loop-runbook.md) completely.
- Before declaring a device or fleet successful, read [references/acceptance-checklist.md](references/acceptance-checklist.md) completely.
- Use `sysupgrade` for an installed OpenWrt system. Use a factory image only for the device's supported first-install path or when the user explicitly requires that path.
- If `/data` is absent or raw, follow the provisioning gates in the runbook. Never infer permission to format from a missing mount.

## Loop contract

Maintain a ledger for each candidate SHA and device. Advance through:

`build -> verify artifact -> preflight -> transfer -> image test -> upgrade -> reconnect -> accept`

On failure, classify it before acting:

- repository/firmware defect: make the smallest general fix, add a focused regression, commit and push the authorized branch, then build a new candidate;
- device configuration or retained-state defect: reconcile only that state when the intended configuration is known and preserve user data;
- ambiguous or destructive recovery: stop and request the missing authority;
- transient build/network/boot delay: retry with a bound, without creating duplicate Actions or reflashing a device already on the candidate.

Only stop when every target runs the same intended candidate (or an explicitly documented per-model candidate set), all required checks pass after reboot, evidence is recorded, and owned temporary files are removed. Stop any scheduler or heartbeat created for the loop when this condition is reached.

## Updating this skill

Update the runbook when a real failure changes a decision, safety boundary, invariant, or validation method. Do not accumulate one-off timestamps, Action IDs, transient IPs, credentials, or logs as permanent instructions. Keep repository and shared copies identical and re-run the skill validator after changes.
