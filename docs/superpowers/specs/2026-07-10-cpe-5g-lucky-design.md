# CPE-5G Lucky Firmware Preset

## Goal

Provide a repeatable firmware build preset for the CPE-connected `re-ss-01` router. The router keeps `192.168.66.0/24` as the CPE management transit network and uses a unique LAN subnet for local services and Headscale management.

## Decisions

- Enable `luci-app-lucky` globally because the owner requested it for all standard firmware builds. The existing package source in `Scripts/Packages.sh` remains the source of truth.
- Add a manual-only `CPE-5G` GitHub Actions workflow based on the existing reusable `WRT-CORE` workflow and keep it aligned with the `QCA-6.18-VIKINGYFY` build track.
- Default the CPE LAN address to `192.168.13.1/24`, avoiding existing `192.168.10.0/24`, `192.168.11.0/24`, and `192.168.12.0/24` allocations.
- Use the existing `IPQ60XX-WIFI-YES` profile, which includes the `jdcloud_re-ss-01` target adjustments.
- Reuse the existing Tailscale and Headscale auto-enrollment overlay. Do not embed enrollment secrets in the repository.
- Superseded by the private-Mesh policy: CPE-5G B enables `WRT_LAN_TAILNET` and explicit bidirectional LAN/Tailnet forwarding, while the no-overlay A isolation baseline remains without the gateway. Headscale ACLs are the Tailnet-to-LAN access boundary.

## Validation

`tests/test_cpe_5g_preset.sh` verifies global Lucky selection, the CPE preset identity, its `192.168.13.1` default, the IPQ60XX profile, the conservative tailnet setting, and this documentation.
