# CPE B Lucky persistence and maintenance

The CPE B overlay mounts a private `/data/lucky` directory on `/etc/lucky`.
It deliberately uses a bind mount, not a symlink: certificate and managed-rule
readers reject symlink parent directories. General router targets are unchanged.

The supervised Lucky worker waits for a real writable ext4/f2fs `/data` block
mount and a terminal wrtbak restore decision. It never starts on tmpfs fallback.
An advisory lock serializes startup with the origin worker. Initial migration
requires Lucky to be stopped, copies all LKCF, authorization, token and
certificate files into a private staging directory, writes a version marker,
then atomically renames it. Existing recognized persistent data wins on later
boots; neither restored overlay files nor ROM defaults overwrite it.

The origin worker mounts the same data before certificate restoration and
managed-rule reconciliation. After restore, the helper replaces a retained old
Lucky launcher only if the ROM contains the CPE guarded launcher. It preserves
UCI enabled, port and SafeURL settings. Empty SafeURL uses offline `-setconf`;
the running-daemon `-rCancelSafeURL` control command cannot be used before startup.

Keep-config sysupgrade includes `/etc/lucky`, `/data/lucky`, and the CPE private
manifests. Back up those together before upgrading. Erasing/repartitioning eMMC
can destroy `/data`; `sysupgrade -n` or reset may also lose UCI/private manifests
even if the data partition survives. Do not treat either operation as a complete
configuration-preservation guarantee. Persisted administrator changes never go
into public Git or generic firmware images.

## DNS permission repair

The CPE origin is its own AliDNS zone, `cpe-origin.jmsu.top`. Keep the dedicated
RAM policy scoped to that exact zone for record writes and reads. Lucky requires
`DescribeSubDomainRecords`, `DescribeDomainRecordInfo` and
`UpdateDomainRecordRemark` in addition to the original domain-record actions.
The existing global `DescribeDomains` discovery permission is not an all-zone
write grant. Do not substitute DNS full access or change the parent zone.

2026-10-06: policy `Cpe5gS13OriginDnsOnly` v3 adds those three zone-scoped actions.
Lucky previously reported a provider authorization error with a valid selected
SIM IPv6. After repair it reports `SYNC_PROVIDER_IP_SAME`; direct scoped query,
record-info and same-remark update pass. A same-value address update returns the
provider's duplicate-record response instead of an authorization failure. No
origin address was changed. Debug is disabled again and TTL remains 600.

The current Wi-Fi B ROM (`50e37ae`, Action `37400726446`) with the field Lucky
persistence patch passed a physical cold boot on 2026-10-06. The SIM prefix
changed, all 16 Lucky LKCF files remained on the eMMC bind mount, Tailnet
returned to Running, and WAN PPPoE became the primary IPv4 route again. Native
DDNS initially met an API connection-refused error, then updated the actual
origin AAAA to the new address. Public UDX checks returned 401 without credentials
and 200 with valid credentials. This verifies convergence after this prefix
change, not uninterrupted availability during boot or every future carrier event.

## Cellular usage continuity

The user clarified that the observed vendor-total decrease followed a manual
clear; it must not be attributed to a cold-boot reset. Separately, the field
vendor total reached about 8 GB while current native cellular counters were
small. The exact cause of that history discrepancy remains unproven. Upstream
UDX710-TOOLS `src/system/traffic.c` removes the vnStat database on clear without
first stopping the daemon; cached state being written back is a plausible risk,
not a confirmed diagnosis of the installed binary. Preserve modem history and
compare independent counters before drawing conclusions.

A 30.08-second live sample showed PPPoE WAN RX+TX rising by 6,178,442 bytes while
modem `sipa_eth0` rose by only 4,030 bytes. OpenWrt `usb0` rose by 106,637 bytes,
including local management/ADB traffic. These counters distinguish this sample's
WAN and cellular use; usb0 total is not a SIM billing total. WAN IPv4 being
primary does not suppress SIM IPv6: the current approved policy keeps cellular
IPv6 available to LAN and public services even while WAN is healthy.

The CPE worker now samples the modem boot ID and native `sipa_eth0` RX/TX byte
counters through the existing serialized ADB transport. A root-private ledger
at `/data/cpe5g-quota/ledger.json` records accumulated usage atomically with fsync
before allowing SIM traffic. Initial enrollment starts a separate native period
with the current modem boot's counters; disputed vendor history is not imported.
Earlier carrier usage is therefore outside this new period and cannot be inferred
from this meter. Later samples add native
counter deltas; a new modem boot adds that boot's counters without replenishing
the previous allowance. Vendor counter resets or wrap inflation no longer
replace the accumulated value. The configured 40 GiB limit is unchanged.

Missing writable eMMC, an unsafe/corrupt ledger or same-boot counter regression
fails closed for SIM IPv4/IPv6 and public access; WAN and LAN management remain
available. Keep-config sysupgrade preserves the ledger. Automatic billing-cycle
reset is intentionally absent: an administrator must reconcile the operator's
billing window and verified usage before starting a new accounting period.
This is a conservative continuity safeguard, not a carrier billing meter;
unsampled traffic around sudden power loss remains a measurement limitation.

An initial maintenance seed conservatively added the previously observed
26,361,560,944-byte floor. After the user explained the manual clear, that exact
maintenance-added floor was removed, with a private backup; the modem database
and configured limit were not changed. The current device ledger retains only
its new native accounting period. Do not restore disputed historical values
against an administrator's intended reset. Clearing the vendor UI and rebasing
this independent eMMC ledger are separate operations; a new verified accounting
period requires an explicit administrator decision, not automatic inference
from a lower vendor total.

Live native increments and a controller restart pass. This accounting patch was
installed after the physical cold boot; a further physical boot remains its
separate gate.

## Acceptance boundaries

WAN link-up/upstream-down tests require an independent Mac-to-CPE LAN rescue
path and a pre-armed timed rollback. Temporary nftables rules must be confined
to a uniquely owned test table and removed before further reboot/USB testing.
Check new LAN connections, WAN-up state, mwan3 policy, local main routes and
automatic recovery. Existing TCP/SSE sessions do not migrate across uplinks.

2026-10-06 live test: with PPPoE still up, a temporary IPv4 drop on `pppoe-wan`
made mwan3 report WAN offline in 7 seconds. The policy switched to SIM and the
main default to usb0; a fresh Mac LAN HTTPS request passed certificate validation.
After removing the fault, WAN was reported online in 11 seconds and reclaimed
both the policy and main default. Those are detector transition times, not a
measured guarantee of per-connection failover latency. The fault table, watchdog
and exact Mac test route were removed. Physical USB insertion/removal remains
pending; no drive was formatted or removed remotely.

Quota tests use the actual controller with injected snapshots/command fixtures;
never reset modem counters or consume the remaining SIM allowance. Exhausted or
unknown quota must close SIM IPv4/IPv6 and public exceptions while leaving WAN
and local management available. Physical quota-stop and billing-cycle rollover
remain separate device gates.

CPA deployment work is paused. This change preserves current domains, existing
API/container state and the WAN/SIM policies; it does not add LLM providers.
