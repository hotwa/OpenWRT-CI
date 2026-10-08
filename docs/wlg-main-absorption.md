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

## Smoke-test integration repair (2026-10-08)

Both cf4e960 builds stopped in Repository Smoke Tests before firmware compilation.
Completed the absorbed agent-data-prep baseline (first-boot enable, executable Pi
settings merger and npm guards), maintenance helper staging, and logd defaults.
Aligned CommandCode/Tailnet/Nikki tests and dependent files to the same reviewed
main snapshot. OpenCode remains an optional compatibility entry; Pi is still the
preferred runtime. The WLG container gate tests the WLG SS01 caller, not an
unmodified CPE caller. LAN tests use workflow basenames and distinguish SS01's
51.1 default from CS07's 50.1. Production fleet CD was intentionally excluded:
the boundary test checks WLG explicit secret allowlists and build-only behavior.
The old wrtbak proxy-patch test was not part of the main snapshot and referenced
a patch that this branch does not install; it is removed rather than injecting
an unrelated backup transport change.

The follow-up CI run exposed stale historical-SHA assertions in the shared-tool
and CommandCode role-link tests after importing the current role card. These
are now aligned with the same main snapshot. The final 118-script local scan
completed; its sole reported role-link failure passed after that correction.

The 9a552dd CI retries passed Repository Smoke Tests and runtime preparation,
but private injection stopped because the retained WLG classifier did not
recognize CommandCode auth JSON. The classifier now treats every injector auth
location as private (including malformed nonempty files), without printing
credentials. An offline integration regression executes the real injector and
classifier together and verifies private classification, suffix and log redaction;
individual canonical auth paths are covered. Public release gates remain intact.
