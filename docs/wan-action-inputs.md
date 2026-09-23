# WAN protocol Action input

The supported manual-build workflows expose a `WAN_PROTOCOL` choice:

- `dhcp` is the default and does not alter the firmware's existing WAN setup.
- `pppoe` configures `network.wan.proto=pppoe` at first boot.

GitHub Actions has no secret workflow-dispatch input. Do not paste a PPPoE
password into an Action form. Before selecting `pppoe`, create these repository
secrets instead:

```text
OPENWRT_WAN_PPPOE_USERNAME
OPENWRT_WAN_PPPOE_PASSWORD
```

The build writes them only as base64 data in a one-shot, root-only UCI-defaults
file. The generated image is marked private and will not be released through
the public artifact path. The UCI defaults applies the credentials before WAN
starts, then the normal first-boot defaults cleanup removes the file.

RE Mesh applies its single `WAN_PROTOCOL` selection to both matrix artifacts.
Use DHCP for a normal mixed-site build; select PPPoE only when both resulting
images are intended to use the same PPPoE account.
