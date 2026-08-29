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

Run the environment probe immediately after login:

```sh
bash "$GITHUB_WORKSPACE/Scripts/ci-debug-probe.sh"
```

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
