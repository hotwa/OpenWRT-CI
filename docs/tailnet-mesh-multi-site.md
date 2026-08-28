# Multi-Site Automated Mesh Tailnet Architecture

## 1. Overview

This document defines the zero-touch, multi-site automated Tailscale/Headscale mesh network architecture used across all hotwa OpenWrt devices (JDCloud Athena \`RE-CS-02\`, Nezha \`RE-SS-01\`, Taiyi \`RE-CS-07\`, CPE-5G, etc.).

Each router is flashed with a dedicated build containing its custom LAN subnet (e.g. \`192.168.11.1\`, \`192.168.10.1\`, \`192.168.12.1\`), and joins the central Headscale controller (\`https://headscale.jmsu.top\`) automatically on first boot, advertising its LAN subnet and accepting remote subnet routes with zero manual intervention.

---

## 2. Core Architectural Components

\`\`\`
                    ┌────────────────────────────────────────────────────────┐
                    │       Central Headscale Controller & Headplane         │
                    │              (https://headscale.jmsu.top)              │
                    │        - ACL Auto-Approvers for 192.168.0.0/16         │
                    │        - MagicDNS Server (100.100.100.100)             │
                    └─────────────────────────┬──────────────────────────────┘
                                              │
                    ┌─────────────────────────┴──────────────────────────────┐
                    │                                                        │
         ┌──────────▼───────────┐                                 ┌──────────▼───────────┐
         │  Site A: RE-CS-02    │                                 │  Site B: RE-CS-07    │
         │  (LAN 192.168.11.0/24)│                                 │  (LAN 192.168.10.0/24)│
         ├──────────────────────┤                                 ├──────────────────────┤
         │ - Tailscale IP:      │   Direct P2P / Peer Relay       │ - Tailscale IP:      │
         │   100.64.0.25        │ ◄─────────────────────────────► │   100.64.0.26        │
         │ - Auto-Advertises:   │                                 │ - Auto-Advertises:   │
         │   192.168.11.0/24    │                                 │   192.168.10.0/24    │
         │ - Route Table 52:    │                                 │ - Route Table 52:    │
         │   192.168.8.0/24     │                                 │   192.168.11.0/24    │
         │   192.168.10.0/24    │                                 │   192.168.8.0/24     │
         │ - Firewall Zone:     │                                 │ - Firewall Zone:     │
         │   lan -> tailscale   │                                 │   lan -> tailscale   │
         │   (SNAT Masquerade)  │                                 │   (SNAT Masquerade)  │
         └──────────┬───────────┘                                 └──────────┬───────────┘
                    │                                                        │
            ┌───────▼────────┐                                       ┌───────▼────────┐
            │ LAN Clients:   │                                       │ LAN Clients:   │
            │ Win11/Phones   │                                       │ Servers/CPE    │
            │ (192.168.11.x) │                                       │ (192.168.10.x) │
            └────────────────┘                                       └────────────────┘
\`\`\`

---

## 3. Tag Roles & Permissions

All router enrollment keys (Pre-Auth Keys) must bind the following 5 tags:

| Tag | Purpose | ACL Authority |
| :--- | :--- | :--- |
| \`tag:openwrt\` | Subnet access passport | Authorized in ACL to receive and access all remote \`192.168.x.0/24\` subnets |
| \`tag:subnet-router\` | Subnet router capability | Authorized to advertise LAN subnets to Headscale |
| \`tag:service-host\` | Infrastructure host | Long-lived node, never expires, accesses internal DNS and services |
| \`tag:ssh-target\` | Tailscale SSH destination | Allows administrative \`tailscale ssh root@<node>\` |
| \`tag:peer-relay-client\` | DERP-less relay client | High-speed direct tunnel traversal through cloud peer relays |

---

## 4. Headscale Controller Configuration

### A. Pre-Auth Key Generation
1. In Headplane (\`https://headplane.jmsu.top/admin/settings\`):
   - Check **Reusable**;
   - Select tags: \`tag:openwrt\`, \`tag:service-host\`, \`tag:subnet-router\`, \`tag:ssh-target\`, \`tag:peer-relay-client\`;
   - Copy the generated \`hskey-auth-...\` key.

### B. Auto-Approvers in ACL (\`https://headplane.jmsu.top/admin/acls\`)
Add the following block to auto-approve subnets advertised by routers:

\`\`\`json
{
  "autoApprovers": {
    "routes": {
      "192.168.0.0/16": [
        "tag:subnet-router",
        "tag:openwrt"
      ],
      "10.0.0.0/8": [
        "tag:subnet-router",
        "tag:openwrt"
      ]
    }
  }
}
\`\`\`

---

## 5. Firmware Zero-Touch Automation Flow

1. **Build Time**:
   - The GitHub Secret \`HEADSCALE_OPENWRT_AUTHKEY\` is injected by CI into \`/etc/tailscale/headscale.authkey\`.
   - The LAN subnet (e.g. \`192.168.11.0/24\`) is derived from \`WRT_IP\` and stored in \`headscale_auto_enroll.main.advertise_routes\`.
   - \`headscale_auto_enroll.main.accept_routes\` is set to \`1\`.

2. **First Boot**:
   - Once WAN obtains an IP, \`/usr/sbin/headscale-auto-enroll\` registers with Headscale.
   - If \`advertise_routes\` is empty, it dynamically derives the subnet from \`uci get network.lan.ipaddr\`.
   - Headscale assigns the 5 tags and automatically approves the advertised subnet.
   - Tailscale populates route table 52 with all peer subnets.
   - The auth key file \`/etc/tailscale/headscale.authkey\` is securely wiped from flash.

3. **MagicDNS Dual-Layer Failover**:
   - **Layer 1 (Native dnsmasq)**: \`/etc/init.d/tailscale-lan-tailnet\` injects \`server=/hs.jmsu.top/100.100.100.100@tailscale0\` into dnsmasq. LAN devices resolve \`*.hs.jmsu.top\` directly even without proxy software.
   - **Layer 2 (Nikki Proxy Bypass)**: \`nikki-sub-merge\` prepends direct rules for \`100.64.0.0/10\` and \`hs.jmsu.top\` pointing to \`100.100.100.100#tailscale0\`, ensuring Fake-IP does not hijack Tailnet traffic.
