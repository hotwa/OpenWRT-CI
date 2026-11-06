# libffi feed-to-core compatibility

The pinned firmware source predates the 2026-10-19 libffi move from the packages
feed to the OpenWrt core. New packages feeds no longer provide it. GLib then
silently uses its bundled libffi; the old GLib InstallDev rule copies its library
and pkg-config file but omits ffi.h. Python's _ctypes build consequently fails,
and there is no standalone libffi runtime package for dependent packages.

Makefile is copied unchanged from OpenWrt commit
[9b835ec6264f3364a22a9c67909f16bf5e5328d1](https://github.com/openwrt/openwrt/commit/9b835ec6264f3364a22a9c67909f16bf5e5328d1).
That commit moves the previous packages-feed recipe without changes. The libffi
source archive remains version 3.4.7 with its upstream SHA256 pin.

ensure_libffi_recipe.py runs after feeds update and before feeds install. It
stages this one recipe only when neither the core nor a feed defines libffi;
existing providers and incomplete destination directories are never overwritten.
Both target development headers and the runtime package come from the same
standalone build. No host header is copied into the target sysroot, no kernel or
firmware source pin is changed, and the signed uv/Python runtime is unaffected.
