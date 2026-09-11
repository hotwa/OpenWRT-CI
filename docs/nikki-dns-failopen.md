# Nikki DNS fail-open guard

`nikki-dns-failopen` protects LAN DNS from one specific half-started failure:
Nikki has installed `table inet nikki`, but mihomo no longer answers the DNS
redirect on port 1053. A completely absent Nikki table is healthy direct mode
and never triggers repair.

## Health and recovery

The guard waits for both a default route and dnsmasq. When the Nikki table is
present, it resolves a unique `probe-<epoch>-<pid>.example.com` name directly
against `127.0.0.1:1053`. It falls back to port 53 only when bind9 `nslookup`
prints `Usage:`, which proves that `-port` is unsupported. A normal lookup
failure must not fall back because the port-53 query would be redirected to the
same mihomo instance and could hide a broken explicit-port probe.

After two consecutive failures, the guard runs `/etc/init.d/nikki restart`.
Nikki's `service_stopped()` calls `cleanup()`, which deletes the nft table before
starting again, so even an invalid profile naturally returns traffic to direct
mode. After the configured settle delay, the guard probes again. If the table
still exists and DNS is still dead, it deletes only `table inet nikki`, records
the fail-open state under `/var/run`, and waits for an operator to repair Nikki.

The restart budget defaults to three attempts per guard process with a ten-minute
cooldown. Before the first healthy observation, two failed cycles are observation
only to avoid first-boot races. The guard never writes UCI, changes routes,
restarts dnsmasq or Tailscale, or reboots the router.

## Configuration and inspection

Settings live in `/etc/config/nikki-dns-failopen`. The defaults are enabled,
60-second checks, failure threshold 2, 600-second restart cooldown, 10-second
settle time, three restart attempts, two pre-baseline observations, and probe
suffix `example.com`.

```sh
/etc/init.d/nikki-dns-failopen status
/usr/sbin/nikki-dns-failopen --status
/usr/sbin/nikki-dns-failopen --once --verbose
logread -e nikki-dns-failopen
```

`/var/run/nikki-dns-failopen.active` means the nft fail-open action was applied.
After correcting Nikki, restart it normally. A later healthy guard cycle clears
the marker; the guard does not automatically re-enable or rewrite Nikki.

## Firmware validation

On a candidate device, verify the bind9 `nslookup -timeout=3 -port=1053` probe,
healthy status, lexical `S99nikki` before `S99nikki-dns-failopen`, and three quiet
monitor cycles. Fault-injection acceptance then covers a stopped mihomo recovered
by restart, an unrecoverable mihomo that deletes the stale table, cooldown and
budget behavior, DNS/HTTP after direct fallback, Tailnet routes, and a full reboot.
Do not perform disruptive fault injection without the approved device recovery
conditions.
