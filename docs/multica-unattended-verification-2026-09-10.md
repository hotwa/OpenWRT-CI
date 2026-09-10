# Provider-specific unattended Multica verification

User authorized unattended Multica task execution on CS02, CS07 and SS01.
Bootstrap now maps actual provider pi to ["--modes","yolo"], opencode to
["--auto"], and rejects unknown providers. Both create/update use this mapping.
Persisted custom_args is compared along with instructions/name/runtime so old
managed Agent state without the new field triggers migration. This is not a
global permission change for manual CLI sessions or removal of explicit denies.

Backed up bootstrap/state before deploying to devices:
CS02 /data/multica-policy-backup-XjWGoZs6;
SS01 /data/multica-policy-backup-v8dd6WXO;
CS07 /data/multica-policy-backup-EtS2tJIS.
Bootstrap reconciled all three successfully without daemon restarts.

Actual backend-issued tests (not direct CLI-only probes):

| Device | Provider | Issue | Task | Result |
| --- | --- | --- | --- | --- |
| CS02 | opencode | AGE-5 | 01a08948-0a1e-7698-a3d3-d5af0c46a5c8 | completed, 45s, 7 tools |
| SS01 | pi | AGE-6 | 01a08948-5e32-73df-af21-2035f8678f74 | completed |
| CS07 | opencode | AGE-7 | 01a08948-631d-7575-9e2d-6a145e3ed200 | completed, 46s, 7 tools |

Each task created its own /data/multica/permission-smoke-DEVICE-20260910
directory, wrote alpha, replaced with beta, read back and ran pwd. Host-side
reads independently confirmed beta for all three. No operator permission
approval was supplied. Tasks/evidence retained, no cleanup of user data.
OpenCode logged --auto instead of the erroneous Pi extension arguments.
Multica's pre-existing --dangerously-skip-permissions is still present; no
binary/wrapper permission bypass was added. Explicit denies remain enforced.

Regression checks: provider mapping, unknown-provider rejection, persisted
argument policy, create/update parity, migration comparison; lifecycle and
auto-enroll suites pass. These tests do not guarantee every future task succeeds:
model/network/explicit-deny/application failures are distinct from prompts.
Firmware builds predating this patch still contain incorrect uniform Pi args.

## Upstream rationale and reconciliation

OpenCode's official permission reference documents `opencode run --auto`:
https://opencode.ai/docs/permissions/
It answers ask requests while honoring deny. Multica's inspected backend
(`4aca890a2`, and current main during review) still passes the legacy
`--dangerously-skip-permissions` and appends filtered custom_args; --auto is
not blocked by that filter. Upstream issue6864 describes the mismatch:
https://github.com/multica-ai/multica/issues/6864
The issue is a reported compatibility problem, not an official guarantee.

Bootstrap checks remote Agent custom_args as well as local policy state,
so changed server arguments cannot be hidden by an unchanged local cache.
Missing or malformed parameter metadata is not treated as matching.
Do not set a global permission=allow override, remove task-context markers,
or modify Multica's format/dir/session flags. Test actual daemon-dispatched
tool use after runtime version changes, not just `--help` or CLI-only chats.
