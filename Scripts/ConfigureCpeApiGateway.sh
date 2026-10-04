#!/bin/sh
set -eu
[ "$#" = 2 ] || { echo 'usage: ConfigureCpeApiGateway.sh <overlay> <true|false>' >&2; exit 1; }
FILES="$1"
case "$2" in false) exit 0;; true) ;; *) exit 1;; esac
[ -d "$FILES" ] && [ -f "$FILES/etc/init.d/containerd-test" ] && [ -x "$FILES/usr/libexec/cpe5g-mwan3-gated-reconcile" ] || { echo 'CPE API requires CPE B and container runtime overlays' >&2; exit 1; }
SOURCE="$(CDPATH= cd -- "$(dirname "$0")/cpe5g-api" && pwd)"
mkdir -p "$FILES/usr/libexec/cpe5g-api" "$FILES/usr/sbin" "$FILES/etc/init.d" "$FILES/etc/config" "$FILES/etc/uci-defaults" "$FILES/lib/upgrade/keep.d"
cp "$SOURCE/model.mjs" "$FILES/usr/libexec/cpe5g-api/model.mjs"
cp "$SOURCE/launcher" "$FILES/usr/sbin/cpe-api"
cp "$SOURCE/init" "$FILES/etc/init.d/cpe-api"
printf '%s\n' "config gateway 'main'" " option enabled '1'" > "$FILES/etc/config/cpe_api"
cat > "$FILES/etc/uci-defaults/98-cpe-api" <<'EOT'
#!/bin/sh
/etc/init.d/cpe-api enable
/etc/init.d/cpe-api start
exit 0
EOT
printf '%s\n' /etc/config/cpe_api /etc/init.d/cpe-api > "$FILES/lib/upgrade/keep.d/cpe-api"
chmod 755 "$FILES/usr/sbin/cpe-api" "$FILES/etc/init.d/cpe-api" "$FILES/etc/uci-defaults/98-cpe-api"
echo 'CPE API: loopback-only managed application staged; local image required'
