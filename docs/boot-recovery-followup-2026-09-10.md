# Boot recovery follow-up

## Findings

CS02 boot refused containerd after bridge subnet readiness failed. Later the
same persisted subnet passed the unchanged read-only predicate. Exact boot-time
route inventory was not captured, so the original transient route cannot be
named with certainty. The demonstrated lifecycle gap was permanent inactivity
after a single boot-time failure despite later network readiness.

CS07 bootstrap exited after a successful Pi fallback and never reconsidered
preferred OpenCode. Existing test projects were absent on CS02/CS07 before
repair; no evidence identifies who removed them. Do not claim those projects
were restored or that retained sysupgrade necessarily deleted them.

## Fixes

- TEST-only iface hook retries an enabled, inactive containerd-test on ifup or
  ifupdate. It uses the normal init gates; no run_without_bridge bypass,
  compose invocation or restart of a live daemon. Actual subnet conflicts
  still fail closed. Network events, not a continuous background watchdog,
  trigger recovery; no event means no extra retry.
- Pi fallback remains usable while bootstrap tries preferred OpenCode up to
  20 times, sleeping30s between attempts. Promotion requires the exact saved
  idle Agent ID and updates only, never creates a replacement. On exhaustion
  it retains Pi and logs the outcome. Remote idle check is not an atomic
  server-side reservation; a later task can race it.

## Live verification

Backups: CS07 /data/boot-repair-backup-3Ro5XS4s;
CS02 /data/boot-repair-backup-kqvPQh1e.
Created NEW projects bootrepair-cs07-20260910 and bootrepair-cs02-20260910.
Rebooted sequentially, never ran compose up/start after either reboot.
Both app IDs remained identical and persisted tokens returned from healthz;
starts.log grew from one line to two. Both boot logs show network-event
readiness retry and bridge enabled, with escape0 unchanged.

CS07 app ID146483b2f1691bbbac247e684b2dfc50ccde644fa640c58421294dc34fd9671d.
CS02 app ID26bb43fde0baacab88c567376f5640011fd3e59f695e74107b02223bf2784994.
Private evidence: cs07-bootrepair-N608XxIC and cs02-bootrepair-Z2rfj1Ga
under the operation state directory.

Do not treat the reboot probe's cached custom_args check as online binding
proof. Additional service API checks confirmed original Agents bound to
OpenCode with --auto; live promotion logs at07:41:50Z (CS07) and07:43:22Z
(CS02). CS02 initially skipped OpenCode version detection (signal:killed),
then automatically rediscovered it at07:43:11Z, followed by promotion.

Focused tests cover gated hook events, disabled/live daemon no-op, failed
readiness propagation, explicit Pi, immediate/delayed OpenCode, finite timeout,
update failure preservation, busy/absent/ambiguous Agent rejection. Existing
36 subnet cases, init gate, TEST staging and Multica lifecycle tests pass.
These are live patches plus normal-reboot evidence, not yet acceptance of a
newly compiled and retained-config-upgraded successor on all three devices.
