# WLG selective main absorption

Source: hotwa/OpenWRT-CI main 6564f4483c34ee0d19689caf16213dddb3229945.

Accepted: Pi native MCP/default runtime, optional unloaded Magic Context; UUID-independent USB boot recovery; Tailnet hotplug state preservation; container/Node/Python persistence and boot recovery; physical-RAM upgrade gate; Linux 6.18.52/NSS exact source 0fb9b10cb9df51fb076470e1dd93d1c30dd89d83.

Excluded: CPE SIM/IPv6/Lucky/quota overlays, Gecoos automatic provisioning, main proxy replacement. WLG retains OpenClash and explicit secret forwarding, custom LAN IP and manual dispatch. Device gates for WLG images remain pending.

## Build and use

- Existing `WLG-RE-CS-07-BUILD.yml` has a `BUILD_TARGET` selector for re-cs-07 / re-ss-01, so branch dispatch can compile either device without adding the new workflow to main.
- Dedicated `WLG-RE-SS-01-BUILD.yml` uses the ordinary Wi-Fi RE-SS-01 target; default LAN is 192.168.51.1. CS07 remains NOWIFI and default LAN 192.168.50.1.
- `WRT_PROXY_PROFILE=openclash` selects luci-app-openclash, dnsmasq-full, tun, nft-tproxy and inet-diag, rejects overlapping Nikki/Momo/DAE packages, and removes Nikki overlay jobs only from this staging tree. Other workflows retain Nikki by default.
- OpenClash package is built from the official pinned master source. No subscription or provider login is included. The plugin manages its Mihomo core through its own installation/update UI; a prebundled Mihomo executable is not introduced by this change.
- Pi default remains CommandCode; its API secret is explicitly forwarded by WLG. Magic Context is installed but not loaded by default.
- Validation: scoped proxy/model fixture, native MCP/Magic Context/Node guards, persistence and upgrade-memory regressions. Full firmware compilation and real-device tests are separate gates.
