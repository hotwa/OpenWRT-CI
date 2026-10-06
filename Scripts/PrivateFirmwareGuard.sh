#!/bin/bash
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"

uci_option_value() {
	local file="$1"
	local section_type="$2"
	local section_name="$3"
	local option_name="$4"

	[ -r "$file" ] || return 0
	awk -v wanted_type="$section_type" -v wanted_name="$section_name" -v wanted_option="$option_name" '
		function unquote(value) {
			if (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") {
				return substr(value, 2, length(value) - 2)
			}
			if (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") {
				return substr(value, 2, length(value) - 2)
			}
			return value
		}
		$1 == "config" {
			section_type = $2
			section_name = unquote($3)
			in_section = (section_type == wanted_type && section_name == wanted_name)
			next
		}
		in_section && $1 == "option" && $2 == wanted_option {
			$1 = ""
			$2 = ""
			sub(/^[ \t]+/, "")
			print unquote($0)
			found = 1
			exit
		}
	' "$file"
}

add_reason() {
	local reason="$1"

	case " $reasons " in
		*" $reason "*) ;;
		*) reasons="${reasons:+$reasons,}$reason" ;;
	esac
}

reasons=
wrtbak_config="$TARGET_FILES/etc/config/wrtbak"
headscale_authkey="$TARGET_FILES/etc/tailscale/headscale.authkey"

# A managed AP preset is a private credential even when no other injector ran.
gecoosac_profile="$TARGET_FILES/etc/gecoosac-auto/profile.json"
if [ -r "$gecoosac_profile" ]; then
	if python3 - "$gecoosac_profile" <<'PY'
import json, sys
try:
    profile = json.load(open(sys.argv[1], encoding='utf-8'))
except (ValueError, OSError):
    # An unreadable credential profile must never be classified as public.
    sys.exit(0)
if not isinstance(profile, dict):
    sys.exit(0)
sys.exit(0 if profile.get('fallback_key') or profile.get('ac_password', 'admin') != 'admin' else 1)
PY
	then
		add_reason gecoosac-wifi-password
	fi
fi

if [ -r "$wrtbak_config" ]; then
	access_key="$(uci_option_value "$wrtbak_config" remote s3 access_key)"
	secret_key="$(uci_option_value "$wrtbak_config" remote s3 secret_key)"
	proxy_url="$(uci_option_value "$wrtbak_config" wrtbak main proxy_url)"
	[ -z "$access_key" ] || add_reason wrtbak-r2-access-key
	[ -z "$secret_key" ] || add_reason wrtbak-r2-secret-key
	[ -z "$proxy_url" ] || add_reason wrtbak-proxy-url
fi

if [ -s "$headscale_authkey" ]; then
	add_reason headscale-authkey
fi

# The CPE IoT PSK is a root-only raw file consumed by a guarded firstboot
# service. It remains recoverable from immutable ROM, so encrypted delivery
# and private classification are required even after the running copy is used.
if [ -s "$TARGET_FILES/etc/cpe5g/wifi.key" ]; then
	add_reason cpe-wifi-credential
fi

# Lucky configuration, API tokens and certificate material are private seeds,
# even when no other build credential was provided. Only file metadata is read.
lucky_private=false
if [ -d "$TARGET_FILES/etc/cpe5g-lucky" ]; then
    while IFS= read -r -d '' lucky_private_file; do
        if [ -s "$lucky_private_file" ]; then
            lucky_private=true
            break
        fi
    done < <(find "$TARGET_FILES/etc/cpe5g-lucky" \( -type f -o -type l \) -print0)
fi
if [ "$lucky_private" = false ]; then
    for lucky_private_file in "$TARGET_FILES/etc/lucky/"*.lkcf \
        "$TARGET_FILES/etc/lucky/cert-sync/lucky.token" \
        "$TARGET_FILES/etc/lucky/cert-sync/cpe5g-openwrt/current/"*.pem \
        "$TARGET_FILES/etc/lucky/cert-sync/cpe5g-openwrt/current/certificate-pin.json" \
        "$TARGET_FILES/etc/lucky/cert-sync/cpe5g-origin/current/"*.pem \
        "$TARGET_FILES/etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json"; do
        if [ -s "$lucky_private_file" ]; then
            lucky_private=true
            break
        fi
    done
fi
[ "$lucky_private" = false ] || add_reason cpe-lucky-private-seed

# The subscription URL is written only by the private build injector, as base64
# in a one-shot UCI-defaults file. It remains recoverable from a firmware image.
nikki_subscription_defaults="$TARGET_FILES/etc/uci-defaults/98-nikki-subscription"
if [ -s "$nikki_subscription_defaults" ] && grep -q 'base64 -d' "$nikki_subscription_defaults"; then
	add_reason nikki-subscription-url
fi

# WAN PPPoE credentials are encoded in a one-shot defaults file so they can be
# applied before the network service starts.  They are still recoverable from
# the firmware image and therefore must never be released as a public artifact.
pppoe_defaults="$TARGET_FILES/etc/uci-defaults/97-wan-pppoe"
if [ -s "$pppoe_defaults" ] && grep -q 'network.wan.password' "$pppoe_defaults"; then
	add_reason wan-pppoe-credential
fi

# Build-time Samba credentials are paired binary databases. Their contents
# are secret even though no plaintext password is present in the overlay.
if [ -s "$TARGET_FILES/etc/samba/passdb.tdb" ] || [ -s "$TARGET_FILES/etc/samba/secrets.tdb" ]; then
	add_reason samba-default-credential
fi

multica_config="$TARGET_FILES/etc/config/multica"
if [ -r "$multica_config" ]; then
	multica_token="$(uci_option_value "$multica_config" multica main token)"
	[ -z "$multica_token" ] || add_reason multica-pat-token
fi

# CommandCode provider API key injected by CommandCodeProviderConfig.sh.
# Either location proves the firmware carries a secret-bearing overlay.
commandcode_auth="$TARGET_FILES/etc/commandcode/auth.json"
pi_agent_auth="$TARGET_FILES/etc/pi/agent/auth.json"
if [ -s "$commandcode_auth" ] || [ -s "$pi_agent_auth" ]; then
	add_reason commandcode-api-key
fi

# The CliProxyAPI provider key is injected as a root-only raw token file so
# it can be passed safely to both login shells and procd without evaluating it.
cliproxyapi_key="$TARGET_FILES/etc/pi/agent/cliproxyapi-api-key"
cliproxyapi_base_secret="$TARGET_FILES/etc/pi/agent/cliproxyapi-base-url-secret"
if [ -s "$cliproxyapi_key" ]; then
	add_reason cliproxyapi-api-key
fi
if [ -s "$cliproxyapi_base_secret" ]; then
	add_reason cliproxyapi-base-url
fi

if [ -n "$reasons" ]; then
	printf 'WRT_PRIVATE_BUILD=true\n'
	printf 'WRT_PRIVATE_BUILD_REASON=%s\n' "$reasons"
	printf 'WRT_ARTIFACT_PRIVACY_SUFFIX=private\n'
	echo "private firmware guard: private-only build detected ($reasons)" >&2
else
	printf 'WRT_PRIVATE_BUILD=false\n'
	printf 'WRT_PRIVATE_BUILD_REASON=\n'
	printf 'WRT_ARTIFACT_PRIVACY_SUFFIX=public\n'
	echo "private firmware guard: no secret-bearing overlay detected" >&2
fi
