`hijack-pinned.ut` is the unchanged GPL-3.0 Nikki template from
`nikkinikki-org/OpenWrt-nikki` at commit
`7b203f6c4c5e94c6c0026acb301090aa1d310e7f`, path
`nikki/files/ucode/hijack.ut`.

SHA256: `d6ecab87c26d3bc093aecd2832dcc26e860bd70cddc66d720e07742330aa78ab`.
It also matches the template extracted from the verified CPE WiFi firmware
`sysupgrade-26.10.04-01.44.45.bin`. The fixture lets selector guard tests
exercise every router mode without depending on a network download.

Native rendering tests use `ucode` when installed. For a extracted firmware
runtime under QEMU, set `NIKKI_TEST_UCODE_COMMAND` to a JSON command array,
for example `["qemu-aarch64-static", "-L", "/tmp/rootfs", "/tmp/rootfs/usr/bin/ucode"]`.
The renderer mocks only UCI, ubus and system lookups; Nikki's actual complete
template and the patched selector collection run under the real interpreter.
