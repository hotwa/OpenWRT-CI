# CI Debug Gate

The CI Debug Gate is an opt-in failure hold for the hosted GitHub Actions
runner. It starts `tailscaled` in `userspace-networking` mode, enables
Tailscale SSH, and holds the job for up to 90 minutes. The Headscale preauth
key assigns `tag:ci-debug` and its ephemeral lifecycle; the client deliberately
does not pass `--advertise-tags`. Touch `/tmp/continue-ci` on the runner to release
the hold; timeout also releases it. Cleanup stops the locally started
`tailscaled` process and removes its temporary state.

The gate uses `tailscale up --auth-key`, not `--ephemeral`: Tailscale 1.94.2
does not document the latter. Short-lived node lifecycle and the debug tag are
supplied by the Headscale preauth key policy (the CI key must be scoped for
`tag:ci-debug` and configured as ephemeral). Passing a redundant
`--advertise-tags=tag:ci-debug` can make Headscale reject registration with
`requested tags ... are invalid or not permitted`, so that flag must stay out
of the client command. The key is injected only through GitHub Actions secrets
and must never be committed.

## Connect from the OpenWrt LAN gateway

After the workflow prints the enrolled `100.64.0.x` address, connect to the
LAN OpenWrt first, then use its Tailscale client as the tailnet path:

```sh
ssh root@192.168.11.1
tailscale status
tailscale ping 100.64.0.x
ssh runner@100.64.0.x
```

The Headscale ACL must allow the OpenWrt node (or its permitted admin tag) to
reach `tag:ci-debug` as SSH user `runner`; Tailscale SSH also has to be enabled
by the enrolled runner's `--ssh` setting. If that ACL is not present, use an
already-authorized tailnet host or the documented ECS gateway path.

Use the full `ci-debug-....hs.jmsu.top` MagicDNS name printed by the setup
script, not the bare `ci-debug-...` host label. Nikki forwards the
`.hs.jmsu.top` suffix to `100.100.100.100`, so the FQDN resolves to the
runner's `100.64.0.x` address. The bare short name does not match that suffix
rule and may receive a `198.18.x.x` Fake-IP address. The enrolled IP remains a
safe fallback.

Run the environment probe immediately after login:

```sh
bash /home/runner/work/OpenWRT-CI/OpenWRT-CI/Scripts/ci-debug-probe.sh
```

An SSH session does not inherit the workflow's `GITHUB_WORKSPACE`; invoke the
probe with its absolute checkout path when entering commands manually. The
probe itself derives the repository root from its own location.

The old Actions run cannot be resumed or have skipped steps restored. Manual
commands on a held runner are for diagnosis only; after applying a fix,
release it and re-run the workflow so GitHub records a complete successful
run. Do not print, copy, or store the auth key, GitHub tokens, Tailscale state,
or private SSH keys.

## Failure signatures

`Repository Smoke Tests` reporting `repository contains a real-looking
Headscale auth key` means a test fixture contains a contiguous `hskey-auth-*`
literal. Split mock literals across adjacent shell strings so the fixture does
not trip the repository secret guard.

`CI Debug Gate` concluding success while logging `WARN: Tailscale debug gate
setup failed` means the gate degraded and no runner was held. Inspect the
preceding Tailscale error before attempting SSH; an enrollment rejection means
there is no reachable runner address.

## Dedicated SSH smoke workflow

Use `.github/workflows/CI-DEBUG-SSH-TEST.yml` for a focused Tailscale SSH
connectivity check without starting a firmware build. Dispatch it with the
`hold_minutes` input (default 30, maximum 90). It requires the repository
secrets `HEADSCALE_CI_AUTHKEY` and `HEADSCALE_URL`, prints the enrolled IP and
`ci-debug-<run_id>-<attempt>` hostname, and holds the runner until a permitted
SSH user runs `touch /tmp/continue-ci` or the timeout safely releases it. The
workflow uses the same `bash` entrypoint and same-step environment-file
contract as the build gate, then always cleans the runner process and temporary
state. Only one smoke run is allowed at a time.

Verified control paths (2026-08-29): run `33262059158` proved direct-IP SSH;
run `33262670362` proved the full `.hs.jmsu.top` FQDN resolves to
`100.64.0.31`, authenticates as `runner` through Tailscale policy, finds the
checked-out probe, and accepts remote `touch /tmp/continue-ci`. Run
`33262873262` then verified the updated
setup output itself prints the full FQDN and ready-to-copy SSH/probe commands;
FQDN login and remote release both succeeded. All three workflows completed
successfully.
