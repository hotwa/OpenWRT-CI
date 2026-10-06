# Pinned mwan3 compatibility fixtures

`mwan3.sh` and `mwan3.init` are unmodified public mwan3 2.12.2-r1 package
scripts from the production CPE package snapshot supplied for this regression
(`mwan3.live.sh` and `mwan3.init.live.sh` in the external acceptance lab).
They contain package implementation only, with no runtime configuration or secrets.
The patcher accepts these exact inputs and refuses source drift.

| Fixture | SHA256 |
| --- | --- |
| `mwan3.sh` | `68bbc58eb102f40e5dad76fa7f022bdb646b641f033a5658ce5aaad59f024b0f` |
| `mwan3.init` | `d3acea623135b44f54dc7c1b29423b5e2195705190fbe0ff66783625af38b01a` |
| `native-mangle.sanitized.json` | `e9d783269b9dc65377f7d942b6a0e2ebd76987d4be4d3c21f462e6bae1b4b702` |

`native-mangle.sanitized.json` preserves the IPv4/IPv6 nft expression structure
of the supplied sanitized acceptance snapshot. It has chain names, counters,
handles, marks, and generic Tailscale native conntrack expressions; no addresses,
keys, authentication material, or private runtime state. Tests replay only its
two native rules per family into a new network namespace. Other rules are
generated locally with public names and comments.

Run `bash tests/test_mwan3_nft_compat.sh`. The Python runner creates a network
namespace and verifies its identity before allowing any nft writes. It skips
kernel tests with an explicit reason when namespace creation or tools are
unavailable; source pin, patch drift, idempotence, and mocked JSON ownership
guard tests still run. Real set-dependent general/create_iface paths report an
explicit skip when ipset or kernel ipset support is absent. Run
`python3 -B tests/test_mwan3_nft_compat.py --no-netns` to verify the source/mock
fallback explicitly without any kernel writes.
OpenWrt configuration, route/ipset inventory, and stop delays are fixture stubs;
iptables, nft, helper, patched policy/status functions, and owned-chain cleanup
execute for real in the isolated namespace. No device or cloud access occurs.
