# Live Multica role synchronization verification

Applied current fixed init and role template via SSH after preserving original
init/template/rendered card in per-device private directories:

- CS02: /data/multica-role-check-u8DGz6qg
- SS01: /data/multica-role-check-jsbT8qJG
- CS07: /data/multica-role-check-t8Pmupjy

Restarted Multica on CS02/SS01 only. CS07 daemon was already healthy;
ran bootstrap reconciliation without restarting it. No credential replacement,
container restart, firmware flash or task security-marker removal.

At 02:43:51Z, server Agent instructions matched local rendered cards after
normalizing trailing newlines stripped by shell command substitution. Existing
Agent IDs were retained, not duplicated:

| Device | Agent ID | Bound provider | Server runtime |
| --- | --- | --- | --- |
| CS02 | 227cfb40-4a22-4285-b8d9-3b294af56c7b | opencode | online |
| SS01 | 23a7c923-0a80-4959-93b8-3f5205dad810 | pi | online |
| CS07 | 16fda2d1-02ec-4cd2-939f-6ced84675019 | opencode | online |

Pi /root/.pi/agent/APPEND_SYSTEM.md, cmdc /root/.commandcode/AGENTS.md and
OpenCode /data/opencode/config/opencode/AGENTS.md resolve to the same rendered
card on all three devices. A residual OpenCode link on SS01 is not proof of an
installed/working OpenCode runtime; its approved provider remains Pi.

Real fresh-session probes passed: Pi on SS01 (--no-tools --no-session), cmdc
on CS02 (plan mode, max one turn, no session, no auto-update), OpenCode on CS07
(plan agent, title role-context-check), each bounded by timeout90.
Prompt did not contain expected paths or attach the role file and instructed
no tools/file reading. All returned daemon CWD /data/multica, task root
/data/multica/workspaces and immutable runtime prohibition. This is combined
behavior/path evidence, not a raw hidden-prompt dump or universal assertion
about every future session and override configuration.

Repository comments now specify: GitHub edits alone are not device updates;
deploy/rebuild template, rerender and reconcile after service start/bootstrap.
Changed hash/name/runtime updates existing Agent; bootstrap exits on success.
Existing CLI sessions are not promised hot reload; local/explicit overrides
and preserved administrator AGENTS files can change what is loaded.
Comment-only updates remain local; this live verification does not claim a
new firmware artifact exists or that full three-device acceptance is complete.
