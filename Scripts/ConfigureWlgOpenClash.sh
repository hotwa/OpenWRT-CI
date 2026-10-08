#!/bin/bash
set -euo pipefail
mode=${1:?}; root=${2:?}; profile=${3:-nikki}
case "$profile" in nikki) exit 0;; openclash) ;; *) echo 'ERROR: unknown proxy profile' >&2; exit 1;; esac
case "$mode" in
configure)
  sed -i -E '/^(# )?CONFIG_PACKAGE_(luci-app-openclash|luci-app-nikki|nikki|luci-app-momo|momo|luci-app-homeproxy|homeproxy|luci-app-daed|daed|dae)(=| )/d' "$root/.config"
  cat >> "$root/.config" <<'EOF'
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-inet-diag=y
# CONFIG_PACKAGE_luci-app-nikki is not set
# CONFIG_PACKAGE_nikki is not set
# CONFIG_PACKAGE_luci-app-momo is not set
# CONFIG_PACKAGE_momo is not set
# CONFIG_PACKAGE_luci-app-homeproxy is not set
# CONFIG_PACKAGE_homeproxy is not set
# CONFIG_PACKAGE_luci-app-daed is not set
# CONFIG_PACKAGE_daed is not set
# CONFIG_PACKAGE_dae is not set
EOF
  # No subscription is injected. Disable Nikki managed jobs and private defaults.
  if [ -d "$root/files" ]; then
    rm -rf "$root/files/etc/nikki" "$root/files/etc/config/nikki"
    find "$root/files/etc/init.d" "$root/files/etc/uci-defaults" "$root/files/etc/hotplug.d" "$root/files/usr/sbin" -type f -name '*nikki*' -delete 2>/dev/null || true
    if [ -f "$root/files/etc/crontabs/root" ]; then sed -i '/nikki-/d' "$root/files/etc/crontabs/root"; fi
  fi
  ;;
verify)
  for package in luci-app-openclash dnsmasq-full kmod-tun kmod-nft-tproxy kmod-inet-diag; do
    grep -Fxq "CONFIG_PACKAGE_${package}=y" "$root/.config" || { echo "ERROR: missing OpenClash package $package" >&2; exit 1; }
  done
  ! grep -Eq '^CONFIG_PACKAGE_(luci-app-nikki|nikki|luci-app-momo|momo|homeproxy|dae|daed)=y$' "$root/.config" || { echo 'ERROR: overlapping proxy selected' >&2; exit 1; }
  ;;
*) exit 1;;
esac
