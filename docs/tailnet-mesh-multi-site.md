# Multi-Site Automated Mesh Tailnet Architecture

## 1. Scope and trust boundaries

Each OpenWrt router joins `https://headscale.jmsu.top`, advertises its own LAN
prefix, accepts approved remote prefixes, and provides private-Mesh forwarding
in both directions. The fw4 `tailscale` zone deliberately keeps
`forward=REJECT`; the overlay adds only explicit `lan -> tailscale` and
`tailscale -> lan` forwardings. It does not turn the zone into an unrestricted
forwarding domain: Headscale ACLs remain the access boundary for Tailnet-origin
traffic.

Firmware upgraded from the earlier one-way gateway schema is promoted once to
the private-Mesh defaults, including an old preserved `enabled='0'` setting.
The stamped schema then preserves a later explicit UCI opt-out.

Every site must have a unique CIDR. Duplicate or overlapping LAN prefixes are a
deployment error, not a high-availability configuration. Keep a controller-side
site/CIDR inventory and reject collisions before building firmware.

## 2. Router identities and enrollment keys

The standard tags describe capabilities:

| Tag | Purpose |
| --- | --- |
| `tag:openwrt` | OpenWrt router identity |
| `tag:subnet-router` | May operate as a subnet router |
| `tag:service-host` | May expose explicitly approved infrastructure services |
| `tag:ssh-target` | Destination for policy-authorized Tailscale SSH |
| `tag:peer-relay-client` | Optional private Peer Relay client |

Grant only the roles required by a particular router. For automatic route
approval, create a distinct site identity such as `tag:site-athena-router`.
A shared `tag:subnet-router` proves that a node is a router; it does not prove
that the node owns a particular site's CIDR.

Pre-auth keys must be one-use, short-lived and issued per device. Leave
**Reusable** disabled. Prefer a just-in-time `provision_url` that returns a
one-use key after device authentication. Embedding `HEADSCALE_OPENWRT_AUTHKEY`
in a private build is a legacy fallback only.

Deleting `/etc/tailscale/headscale.authkey` after enrollment removes the writable
overlay path. It cannot erase a copy embedded in immutable SquashFS (`/rom`) or
in the original GitHub artifact. Keep such artifacts private and revoke or
expire the key even after successful first boot.

## 3. Exact-prefix route approval

Never auto-approve an entire RFC1918 aggregate. Approve each site's exact prefix
for a site-scoped identity, for example:

```json
{
  "autoApprovers": {
    "routes": {
      "192.168.11.0/24": ["tag:site-athena-router"],
      "192.168.12.0/24": ["tag:site-taiyi-router"],
      "192.168.13.0/24": ["tag:site-nezha-router"]
    }
  }
}
```

Run `headscale policy check` before deployment. This repository intentionally
does not edit the live Headscale policy. Removing unused reusable keys and
deploying controller policy remain audited operations tasks.

## 4. Firmware and first-boot flow

At runtime, `/usr/sbin/headscale-auto-enroll` reads the active LAN IPv4 address
and prefix from ubus, with UCI as a fallback. The advertised route must exactly
equal that active LAN prefix and must remain within `/24`-`/30`. `WRT_IP` is a
build/UI default only: the runtime overwrites a stale preserved
`advertise_routes` setting with the active prefix before both new enrollment and
`tailscale set` on an already-enrolled node.

For a `192.168.0.0/16` multi-site plan, assign each router one unique `/24` and
approve that exact CIDR for that router's site tag. A router must never
advertise the whole `/16`: that would overlap every other site and turn a
single compromised router into a route for the entire private address pool.
With `accept_routes=1` and the private-Mesh forwardings enabled, every
controller-approved site `/24` is reachable in both directions after flash.

The wrtbak gate remains authoritative: restored Tailscale state is reloaded
before a new key is consumed. Successful new, restored and already-enrolled
paths all remove a residual writable auth-key file and reapply DNS/Nikki health
guards.

`accept_routes=1` is the private-build/Tailnet gateway default. Validate table
52, Nikki marks, WireGuard and other policy-routing plugins on real hardware
before promotion.

## 5. MagicDNS and transparent proxy coexistence

The design uses two persistent layers:

1. The DNS mode guard installs
   `server=/hs.jmsu.top/100.100.100.100@tailscale0` in dnsmasq. It watches both
   `dhcp` and `mosdns` configuration changes, restoring this conditional route
   after mosdns rewrites dnsmasq's server list. It does not patch generated
   `/var/etc/mosdns.json`, which mosdns would overwrite on reload.
2. The Nikki guard stores DIRECT rules, Fake-IP filters and the Quad100
   nameserver policy in Nikki UCI mixins. These are regenerated on every local
   profile or subscription reload. The protected destinations are
   `hs.jmsu.top`, `ts.net`, `100.64.0.0/10`, `fd7a:115c:a1e0::/48` and RFC1918
   routes.

Until `tailscale0` is ready, only `*.hs.jmsu.top` fails closed. The Headscale,
Headplane and DERP bootstrap names use non-Tailnet DNS, so Tailnet enrollment
does not depend on MagicDNS and cannot form a bootstrap DNS loop.

## 6. Required operational checks

- Maintain a unique site/CIDR registry outside firmware inputs.
- Revoke unused reusable or untagged pre-auth keys.
- Test exact-prefix approvals and ACLs in a staging policy before deployment.
- Verify `ip route show table 52`, `nft list ruleset`, Nikki generated rules and
  `nslookup <node>.hs.jmsu.top 100.100.100.100` after every proxy upgrade.
- Keep Dropbear key-based LAN SSH as the independent rescue path.
