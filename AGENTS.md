# AGENTS.md

## Headscale auto-enroll

- Read `docs/headscale-auto-enroll.md` before changing the Tailscale or Headscale first-boot path.
- Do not commit a real Headscale auth key, GitHub token, Tailscale state file, or private SSH key.
- The firmware overlay may contain `/etc/config/headscale_auto_enroll`, but it must remain disabled by default unless a private CI build injects a secret at build time.
- Keep `accept_dns=0` by default. DNS control belongs to dnsmasq, mosdns, Nikki, or DAE.
- Keep `accept_routes=0` by default. Route acceptance can conflict with WireGuard, DAE, Nikki, or WAN policy routing.
- Tailscale SSH does not require replacing Dropbear or installing OpenSSH server. Keep Dropbear key-based SSH as the LAN/rescue path.
- For router auth keys, prefer Headscale preauth keys scoped to `tag:service-host`, `tag:ssh-target`, and `tag:subnet-router`; add `tag:peer-relay-client` only for routers that should use Peer Relay.
