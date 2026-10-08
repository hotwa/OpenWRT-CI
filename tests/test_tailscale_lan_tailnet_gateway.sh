#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAILSCALE_CONFIG="$ROOT_DIR/files/etc/config/tailscale"
FALLBACK="$ROOT_DIR/files/etc/uci-defaults/96-tailscale-uci-fallback"
GATEWAY_INIT="$ROOT_DIR/files/etc/init.d/tailscale-lan-tailnet"
GATEWAY_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/91-tailscale-lan-tailnet"
MAGICDNS_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/98-tailscale-magicdns-forward"
NIKKI_BOOT_GUARD="$ROOT_DIR/files/etc/init.d/tailscale-nikki-guard"

for file in "$TAILSCALE_CONFIG" "$FALLBACK" "$GATEWAY_INIT" "$GATEWAY_DEFAULTS" "$MAGICDNS_DEFAULTS" "$NIKKI_BOOT_GUARD"; do
	[ -f "$file" ] || {
		echo "missing LAN-to-tailnet gateway file: $file"
		exit 1
	}
done

sh -n "$GATEWAY_INIT"
sh -n "$GATEWAY_DEFAULTS"

[ "$(git ls-files --stage -- "$GATEWAY_INIT" | awk '{print $1}')" = "100755" ] || {
	echo "tailscale LAN-to-tailnet init script is not marked executable"
	exit 1
}

[ "$(git ls-files --stage -- "$GATEWAY_DEFAULTS" | awk '{print $1}')" = "100755" ] || {
	echo "tailscale LAN-to-tailnet defaults script is not marked executable"
	exit 1
}

tr -d '\r' <"$TAILSCALE_CONFIG" | grep "^config lan_to_tailnet 'lan_to_tailnet'$" >/dev/null || {
	echo "tailscale config missing lan_to_tailnet section"
	exit 1
}

tr -d '\r' <"$TAILSCALE_CONFIG" | grep "^	option enabled '1'$" >/dev/null || {
	echo "lan_to_tailnet must be enabled by default"
	exit 1
}

for expected in \
	"option cidr4 '100.64.0.0/10'" \
	"option cidr6 'fd7a:115c:a1e0::/48'" \
	"option dns_domain 'hs.jmsu.top'" \
	"option magicdns '100.100.100.100'" \
	"option masq '1'" \
	"option tailnet_to_lan '1'" \
	"option mesh_schema_version '2'"; do
	grep -q "$expected" "$TAILSCALE_CONFIG" || {
		echo "tailscale config missing $expected"
		exit 1
	}
	grep -q "$expected" "$FALLBACK" || {
		echo "tailscale UCI fallback missing $expected"
		exit 1
	}
done

grep -q '/etc/init.d/tailscale-lan-tailnet enable' "$GATEWAY_DEFAULTS" || {
	echo "defaults script does not enable tailscale-lan-tailnet"
	exit 1
}

grep -q '/etc/init.d/tailscale-lan-tailnet start' "$GATEWAY_DEFAULTS" || {
	echo "defaults script does not start tailscale-lan-tailnet"
	exit 1
}

# uci-defaults scripts are removed only after a zero exit. Verify both service
# actions propagate failure so an incomplete first-boot setup is retried.
defaults_fixture_dir="$(mktemp -d)"
defaults_mock_init="$defaults_fixture_dir/tailscale-lan-tailnet"
defaults_test_script="$defaults_fixture_dir/91-tailscale-lan-tailnet"
defaults_call_log="$defaults_fixture_dir/calls"
printf '%s\n' \
	'#!/bin/sh' \
	'printf "%s\\n" "$1" >>"$MOCK_CALL_LOG"' \
	'[ "$1" != "$MOCK_FAIL_ACTION" ]' >"$defaults_mock_init"
chmod 0755 "$defaults_mock_init"
sed "s#/etc/init.d/tailscale-lan-tailnet#$defaults_mock_init#g" \
	"$GATEWAY_DEFAULTS" >"$defaults_test_script"

set +e
MOCK_CALL_LOG="$defaults_call_log" MOCK_FAIL_ACTION='start' sh "$defaults_test_script"
defaults_status=$?
set -e
[ "$defaults_status" -ne 0 ] || {
	echo 'defaults script ignored tailscale-lan-tailnet start failure'
	exit 1
}
[ "$(tr '\n' ' ' <"$defaults_call_log")" = 'enable start ' ] || {
	echo 'defaults script did not run enable then start before propagating start failure'
	exit 1
}

: >"$defaults_call_log"
set +e
MOCK_CALL_LOG="$defaults_call_log" MOCK_FAIL_ACTION='enable' sh "$defaults_test_script"
defaults_status=$?
set -e
[ "$defaults_status" -ne 0 ] || {
	echo 'defaults script ignored tailscale-lan-tailnet enable failure'
	exit 1
}
[ "$(tr '\n' ' ' <"$defaults_call_log")" = 'enable ' ] || {
	echo 'defaults script continued to start after enable failed'
	exit 1
}

rm -f "$defaults_mock_init" "$defaults_test_script" "$defaults_call_log"
rmdir "$defaults_fixture_dir"

grep -q 'config_load tailscale' "$GATEWAY_INIT" || {
	echo "gateway script does not load tailscale UCI"
	exit 1
}

grep -q "config_get enabled.*lan_to_tailnet" "$GATEWAY_INIT" || {
	echo "gateway script does not gate on lan_to_tailnet enabled"
	exit 1
}

grep -q 'ensure_default_option "tailscale.\$SECTION.enabled" "1"' "$GATEWAY_INIT" || {
	echo "gateway script must set default LAN-to-tailnet switch to 1"
	exit 1
}

grep -q 'MESH_SCHEMA_VERSION="2"' "$GATEWAY_INIT" || {
	echo "gateway script must mark the private Mesh configuration schema"
	exit 1
}

grep -q 'ensure_option "tailscale.\$SECTION.enabled" "1"' "$GATEWAY_INIT" || {
	echo "gateway script must migrate a legacy disabled gateway once"
	exit 1
}

if grep -q 'ensure_option "tailscale.\$SECTION.enabled" "0"' "$GATEWAY_INIT"; then
	echo "gateway script must not reset lan_to_tailnet.enabled on every start"
	exit 1
fi

for expected in \
	"firewall.tailscale.forward='REJECT'" \
	"firewall.tailscale.input='ACCEPT'" \
	"firewall.tailscale.output='ACCEPT'" \
	"firewall.tailscale.masq" \
	"src='lan'" \
	"dest='tailscale'"; do
	grep -q "$expected" "$GATEWAY_INIT" || {
		echo "gateway script missing firewall guard: $expected"
		exit 1
	}
	done

for expected in \
	'firewall.allow_tailscale_udp' \
	'firewall.allow_tailscale_udp.name" "Allow-Tailscale-UDP"' \
	'firewall.allow_tailscale_udp.src" "wan"' \
	'firewall.allow_tailscale_udp.proto" "udp"' \
	'firewall.allow_tailscale_udp.dest_port" "41641"' \
	'firewall.allow_tailscale_udp.target" "ACCEPT"'; do
	grep -F "$expected" "$GATEWAY_INIT" >/dev/null || {
		echo "gateway script missing Tailscale WAN UDP rule: $expected"
		exit 1
	}
done

grep -q 'firewall.tailscale_tailnet_to_lan.src" "tailscale"' "$GATEWAY_INIT" || {
	echo "gateway script does not add explicit tailnet-to-LAN forwarding"
	exit 1
}

grep -q 'firewall.tailscale_tailnet_to_lan.dest" "lan"' "$GATEWAY_INIT" || {
	echo "gateway script tailnet-to-LAN forwarding does not target LAN"
	exit 1
}

grep -q 'firewall.tailscale.forward" "REJECT"' "$GATEWAY_INIT" || {
	echo "gateway script must retain default tailscale-zone forwarding rejection"
	exit 1
}

for legacy_option in \
	'firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet' \
	'firewall.tailscale_lan_to_tailnet.cidr4' \
	'firewall.tailscale_lan_to_tailnet.cidr6' \
	'firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan'; do
	grep -F "$legacy_option" "$GATEWAY_INIT" >/dev/null || {
		echo "gateway script does not clean legacy fw4 option: $legacy_option"
		exit 1
	}
	if grep -F "ensure_option \"$legacy_option\"" "$GATEWAY_INIT" >/dev/null; then
		echo "gateway script must not recreate legacy fw4 option: $legacy_option"
		exit 1
	fi
done

start_body="$(sed -n '/^start() {$/,/^}$/p' "$GATEWAY_INIT")"
grep -F 'cleanup_legacy_firewall_options' <<<"$start_body" >/dev/null || {
	echo 'gateway script must clean legacy fw4 options on every reconciliation'
	exit 1
}

# Exercise the firewall reconciler with a minimal in-memory UCI mock. This
# proves that preserved legacy metadata is removed, supported forwarding
# semantics remain intact, tailscale-owned CIDRs are untouched, and a second
# reconciliation is idempotent.
gateway_lib="$(mktemp)"
gateway_full_lib="$(mktemp)"
trap 'rm -f "$gateway_lib" "$gateway_full_lib"' EXIT
sed -e '/^\. \/lib\/functions\.sh$/d' -e '/^start() {$/,$d' "$GATEWAY_INIT" >"$gateway_lib"
sed -e '/^\. \/lib\/functions\.sh$/d' "$GATEWAY_INIT" >"$gateway_full_lib"
(
	mock_config_dir="$(mktemp -d)"
	mock_default_savedir="$(mktemp -d)"
	: >"$mock_config_dir/firewall"
	FIREWALL_CONFIG_DIR="$mock_config_dir"
	FIREWALL_UCI_DEFAULT_SAVEDIR="$mock_default_savedir"
	declare -A mock_uci=(
		[firewall.tailscale.device]='tailscale0'
		[firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet]='1'
		[firewall.tailscale_lan_to_tailnet.cidr4]='100.64.0.0/10'
		[firewall.tailscale_lan_to_tailnet.cidr6]='fd7a:115c:a1e0::/48'
		[firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan]='1'
		[tailscale.lan_to_tailnet.cidr4]='100.64.0.0/10'
		[tailscale.lan_to_tailnet.cidr6]='fd7a:115c:a1e0::/48'
	)
	commit_count=0
	transaction_package=''
	transaction_confdir=''
	transaction_count=0
	pending_changes="firewall.operator.note='pending-operator-note'"

	uci() {
		local isolated=0
		local confdir='' override_dir='' savedir=''
		while :; do
			case "${1:-}" in
				-c) isolated=1; confdir="$2"; shift 2 ;;
				-C) override_dir="$2"; shift 2 ;;
				-t) savedir="$2"; shift 2 ;;
				-q) shift ;;
				*) break ;;
			esac
		done
		local command="${1:-}"
		local argument="${2:-}"
		local package key value
		if [ "$isolated" -eq 1 ]; then
			[ "$confdir" != "$FIREWALL_CONFIG_DIR" ] || return 1
			[ "$override_dir" = "$confdir/override" ] || return 1
			[ "$savedir" = "$confdir/delta" ] || return 1
			package="${argument%%.*}"
			case "$package" in
				tailscale_fw_*) ;;
				*) return 1 ;;
			esac
			if [ "$transaction_confdir" != "$confdir" ]; then
				transaction_confdir="$confdir"
				transaction_package="$package"
				transaction_count=$((transaction_count + 1))
			else
				[ "$transaction_package" = "$package" ] || return 1
			fi
			if [ "$argument" != "$package" ]; then
				argument="firewall.${argument#*.}"
			fi
		fi
		case "$command" in
			get)
				[ "$isolated" -eq 1 ] && [ "$argument" = "$transaction_package" ] && return 0
				[[ -v "mock_uci[$argument]" ]] || return 1
				printf '%s\n' "${mock_uci[$argument]}"
				;;
			set|add_list)
				key="${argument%%=*}"
				value="${argument#*=}"
				mock_uci["$key"]="$value"
				;;
			delete)
				unset 'mock_uci[$argument]'
				;;
			commit)
				commit_count=$((commit_count + 1))
				;;
			changes)
				[ "$isolated" -eq 0 ] || return 1
				[ "$argument" = 'firewall' ] || return 1
				printf '%s\n' "$pending_changes"
				;;
			*)
				echo "unexpected mock uci command: $command" >&2
				return 1
				;;
		esac
	}

	# shellcheck disable=SC1090
	source "$gateway_lib"
	before_changes="$(uci changes firewall)"
	cleanup_legacy_firewall_options
	after_changes="$(uci changes firewall)"
	[ "$after_changes" = "$before_changes" ]
	[ "$after_changes" = "$pending_changes" ]
	apply_firewall '1' '1'

	for legacy_option in \
		firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet \
		firewall.tailscale_lan_to_tailnet.cidr4 \
		firewall.tailscale_lan_to_tailnet.cidr6 \
		firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan; do
		[[ ! -v "mock_uci[$legacy_option]" ]] || {
			echo "legacy fw4 option survived reconciliation: $legacy_option"
			exit 1
		}
	done

	[ "${mock_uci[firewall.tailscale_lan_to_tailnet.src]}" = 'lan' ]
	[ "${mock_uci[firewall.tailscale_lan_to_tailnet.dest]}" = 'tailscale' ]
	[ "${mock_uci[firewall.tailscale_lan_to_tailnet.enabled]}" = '1' ]
	[ "${mock_uci[firewall.tailscale_tailnet_to_lan.src]}" = 'tailscale' ]
	[ "${mock_uci[firewall.tailscale_tailnet_to_lan.dest]}" = 'lan' ]
	[ "${mock_uci[firewall.tailscale_tailnet_to_lan.enabled]}" = '1' ]
	[ "${mock_uci[tailscale.lan_to_tailnet.cidr4]}" = '100.64.0.0/10' ]
	[ "${mock_uci[tailscale.lan_to_tailnet.cidr6]}" = 'fd7a:115c:a1e0::/48' ]
	[ "$commit_count" -ge 1 ]
	first_commit_count="$commit_count"

	cleanup_legacy_firewall_options
	apply_firewall '1' '1'
	[ "$commit_count" -eq "$first_commit_count" ] || {
		echo 'firewall reconciliation is not idempotent'
		exit 1
	}
	[ "$transaction_count" -eq 2 ]
	rm -f "$mock_config_dir/firewall"
	rmdir "$mock_config_dir" "$mock_default_savedir"
)

# Failure injection exercises a real two-layer UCI model: committed values are
# visible to the private `uci -t` transaction, while an unrelated operator
# delta remains visible only through ordinary `uci changes firewall`. Neither
# a mid-sequence delete failure nor a commit failure may alter either layer.
exercise_cleanup_failure() (
	local failure_mode="$1"
	local mock_config_dir
	local mock_default_savedir
	mock_config_dir="$(mktemp -d)"
	mock_default_savedir="$(mktemp -d)"
	: >"$mock_config_dir/firewall"
	FIREWALL_CONFIG_DIR="$mock_config_dir"
	FIREWALL_UCI_DEFAULT_SAVEDIR="$mock_default_savedir"
	declare -A committed_uci=(
		[firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet]='legacy-forward'
		[firewall.tailscale_lan_to_tailnet.cidr4]='100.64.0.0/10'
		[firewall.tailscale_lan_to_tailnet.cidr6]='fd7a:115c:a1e0::/48'
		[firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan]='legacy-reverse'
		[firewall.operator.note]='committed-note'
	)
	declare -A transaction_deletes=()
	local pending_changes="firewall.operator.note='pending-operator-note'"
	local before_changes
	local after_changes
	local delete_count=0
	local commit_count=0
	local log_text=''
	local transaction_package=''
	local transaction_confdir=''

	uci() {
		local isolated=0
		local confdir='' override_dir='' savedir=''
		while :; do
			case "${1:-}" in
				-c) isolated=1; confdir="$2"; shift 2 ;;
				-C) override_dir="$2"; shift 2 ;;
				-t) savedir="$2"; shift 2 ;;
				-q) shift ;;
				*) break ;;
			esac
		done
		local command="${1:-}"
		local argument="${2:-}"
		local package key
		if [ "$isolated" -eq 1 ]; then
			[ "$confdir" != "$FIREWALL_CONFIG_DIR" ] || return 1
			[ "$override_dir" = "$confdir/override" ] || return 1
			[ "$savedir" = "$confdir/delta" ] || return 1
			package="${argument%%.*}"
			case "$package" in
				tailscale_fw_*) ;;
				*) return 1 ;;
			esac
			[ -z "$transaction_package" ] && transaction_package="$package"
			[ "$transaction_package" = "$package" ] || return 1
			[ -z "$transaction_confdir" ] && transaction_confdir="$confdir"
			[ "$transaction_confdir" = "$confdir" ] || return 1
			if [ "$argument" != "$package" ]; then
				argument="firewall.${argument#*.}"
			fi
		fi
		case "$command" in
			get)
				if [ "$isolated" -eq 1 ] && [[ -v "transaction_deletes[$argument]" ]]; then
					return 1
				fi
				[[ -v "committed_uci[$argument]" ]] || return 1
				printf '%s\n' "${committed_uci[$argument]}"
				;;
			delete)
				[ "$isolated" -eq 1 ] || return 1
				delete_count=$((delete_count + 1))
				if [ "$failure_mode" = 'delete' ] && [ "$delete_count" -eq 3 ]; then
					return 1
				fi
				[[ -v "committed_uci[$argument]" ]] || return 1
				transaction_deletes["$argument"]=1
				;;
			commit)
				[ "$isolated" -eq 1 ] || return 1
				[ "$argument" = "$transaction_package" ] || return 1
				commit_count=$((commit_count + 1))
				[ "$failure_mode" != 'commit' ] || return 1
				for key in "${!transaction_deletes[@]}"; do
					unset 'committed_uci[$key]'
				done
				;;
			changes)
				[ "$isolated" -eq 0 ] || return 1
				[ "$argument" = 'firewall' ] || return 1
				printf '%s\n' "$pending_changes"
				;;
			*)
				echo "unexpected mock uci command: $command" >&2
				return 1
				;;
		esac
	}

	logger() {
		log_text="$*"
	}

	# shellcheck disable=SC1090
	source "$gateway_lib"
	before_changes="$(uci changes firewall)"
	if cleanup_legacy_firewall_options; then
		echo "legacy firewall cleanup ignored injected $failure_mode failure"
		exit 1
	fi
	after_changes="$(uci changes firewall)"

	[ "$(uci -q get firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet)" = 'legacy-forward' ]
	[ "$(uci -q get firewall.tailscale_lan_to_tailnet.cidr4)" = '100.64.0.0/10' ]
	[ "$(uci -q get firewall.tailscale_lan_to_tailnet.cidr6)" = 'fd7a:115c:a1e0::/48' ]
	[ "$(uci -q get firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan)" = 'legacy-reverse' ]
	[ "$after_changes" = "$before_changes" ]
	[ "$after_changes" = "$pending_changes" ]
	[ "$firewall_changed" -eq 0 ]
	case "$transaction_package" in
		tailscale_fw_*) ;;
		*) echo 'cleanup did not use a unique UCI package alias' >&2; exit 1 ;;
	esac

	case "$failure_mode" in
		delete)
			[ "$delete_count" -eq 3 ]
			[ "$commit_count" -eq 0 ]
			[[ "$log_text" == *'failed to delete legacy UCI option'* ]]
			;;
		commit)
			[ "$delete_count" -eq 4 ]
			[ "$commit_count" -eq 1 ]
			[[ "$log_text" == *'failed to commit legacy firewall option cleanup'* ]]
			;;
		*)
			echo "unknown cleanup failure mode: $failure_mode" >&2
			exit 1
			;;
	esac

	rm -f "$mock_config_dir/firewall"
	rmdir "$mock_config_dir" "$mock_default_savedir"
)

exercise_cleanup_failure delete
exercise_cleanup_failure commit

# Exercise the complete disabled-policy start path. Even though managed
# forwarding creation is skipped, a committed legacy cleanup must be logged
# and applied to the live firewall exactly once.
(
	mock_config_dir="$(mktemp -d)"
	mock_default_savedir="$(mktemp -d)"
	: >"$mock_config_dir/firewall"
	FIREWALL_CONFIG_DIR="$mock_config_dir"
	FIREWALL_UCI_DEFAULT_SAVEDIR="$mock_default_savedir"
	declare -A mock_uci=(
		[tailscale.lan_to_tailnet]='lan_to_tailnet'
		[tailscale.lan_to_tailnet.mesh_schema_version]='2'
		[tailscale.lan_to_tailnet.enabled]='0'
		[tailscale.lan_to_tailnet.tailnet_to_lan]='1'
		[tailscale.lan_to_tailnet.cidr4]='100.64.0.0/10'
		[tailscale.lan_to_tailnet.cidr6]='fd7a:115c:a1e0::/48'
		[tailscale.lan_to_tailnet.dns_domain]='hs.jmsu.top'
		[tailscale.lan_to_tailnet.magicdns]='100.100.100.100'
		[tailscale.lan_to_tailnet.masq]='1'
		[dropbear.main]='dropbear'
		[dropbear.main.enable]='1'
		[dropbear.main.Port]='22'
		[firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet]='1'
		[firewall.tailscale_lan_to_tailnet.cidr4]='100.64.0.0/10'
		[firewall.tailscale_lan_to_tailnet.cidr6]='fd7a:115c:a1e0::/48'
		[firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan]='1'
	)
	firewall_commit_count=0
	reload_count=0
	log_count=0
	log_text=''
	transaction_package=''
	transaction_confdir=''

	uci() {
		local isolated=0
		local confdir='' override_dir='' savedir=''
		while :; do
			case "${1:-}" in
				-c) isolated=1; confdir="$2"; shift 2 ;;
				-C) override_dir="$2"; shift 2 ;;
				-t) savedir="$2"; shift 2 ;;
				-q) shift ;;
				*) break ;;
			esac
		done
		local command="${1:-}"
		local argument="${2:-}"
		local package key value
		if [ "$isolated" -eq 1 ]; then
			[ "$confdir" != "$FIREWALL_CONFIG_DIR" ] || return 1
			[ "$override_dir" = "$confdir/override" ] || return 1
			[ "$savedir" = "$confdir/delta" ] || return 1
			package="${argument%%.*}"
			case "$package" in
				tailscale_fw_*) ;;
				*) return 1 ;;
			esac
			[ -z "$transaction_package" ] && transaction_package="$package"
			[ "$transaction_package" = "$package" ] || return 1
			[ -z "$transaction_confdir" ] && transaction_confdir="$confdir"
			[ "$transaction_confdir" = "$confdir" ] || return 1
			if [ "$argument" != "$package" ]; then
				argument="firewall.${argument#*.}"
			fi
		fi
		case "$command" in
			get)
				[[ -v "mock_uci[$argument]" ]] || return 1
				printf '%s\n' "${mock_uci[$argument]}"
				;;
			set|add_list)
				key="${argument%%=*}"
				value="${argument#*=}"
				mock_uci["$key"]="$value"
				;;
			delete)
				unset 'mock_uci[$argument]'
				;;
			commit)
				[ "$isolated" -eq 1 ] || return 1
				[ "$argument" = "$transaction_package" ] &&
					firewall_commit_count=$((firewall_commit_count + 1))
				;;
			rename)
				return 1
				;;
			*)
				echo "unexpected mock uci command: $command" >&2
				return 1
				;;
		esac
	}

	touch() {
		[ "${1:-}" = '/etc/config/tailscale' ]
	}

	config_load() {
		[ "${1:-}" = 'tailscale' ]
	}

	config_get() {
		local destination="$1"
		local section="$2"
		local option="$3"
		local default_value="${4:-}"
		local key="tailscale.$section.$option"
		local value="$default_value"

		if [[ -v "mock_uci[$key]" ]]; then
			value="${mock_uci[$key]}"
		fi
		printf -v "$destination" '%s' "$value"
	}

	logger() {
		log_count=$((log_count + 1))
		log_text="$*"
	}

	# shellcheck disable=SC1090
	source "$gateway_full_lib"
	reload_services() {
		reload_count=$((reload_count + 1))
		[ "$firewall_changed" -eq 1 ]
	}

	start
	[ "$firewall_commit_count" -eq 1 ]
	[ "$reload_count" -eq 1 ]
	[ "$log_count" -eq 1 ]
	[[ "$log_text" == *'gateway policy is disabled'* ]]
	[[ ! -v 'mock_uci[firewall.tailscale_lan_to_tailnet.tailscale_lan_to_tailnet]' ]]
	[[ ! -v 'mock_uci[firewall.tailscale_lan_to_tailnet.cidr4]' ]]
	[[ ! -v 'mock_uci[firewall.tailscale_lan_to_tailnet.cidr6]' ]]
	[[ ! -v 'mock_uci[firewall.tailscale_tailnet_to_lan.tailscale_tailnet_to_lan]' ]]
	[[ ! -v 'mock_uci[firewall.tailscale]' ]]
	[[ ! -v 'mock_uci[dhcp.@dnsmasq[0].server]' ]]
	case "$transaction_package" in
		tailscale_fw_*) ;;
		*) echo 'disabled cleanup did not use a unique UCI package alias' >&2; exit 1 ;;
	esac
	rm -f "$mock_config_dir/firewall"
	rmdir "$mock_config_dir" "$mock_default_savedir"
)

for expected in \
	'ensure_dropbear_access' \
	"dropbear.@dropbear[0]=main" \
	'for option in Interface DirectInterface _direct' \
	'dropbear.main.$option' \
	'/etc/init.d/dropbear ] && /etc/init.d/dropbear restart'; do
	grep -F "$expected" "$GATEWAY_INIT" >/dev/null || {
		echo "gateway script does not persist Dropbear tailnet access: $expected"
		exit 1
	}
done

for expected in \
	"/hs.jmsu.top/100.100.100.100@tailscale0" \
	"dhcp.@dnsmasq[0].rebind_domain" \
	"hs.jmsu.top" \
	"100.100.100.100@tailscale0"; do
	grep -F "$expected" "$GATEWAY_INIT" >/dev/null || {
		echo "gateway script missing DNS guard: $expected"
		exit 1
	}
done

for expected in \
	"/hs.jmsu.top/100.100.100.100@tailscale0" \
	"dhcp.@dnsmasq[0].rebind_domain"; do
	grep -F "$expected" "$MAGICDNS_DEFAULTS" >/dev/null || {
		echo "MagicDNS defaults missing $expected"
		exit 1
	}
done

for expected in \
	"/etc/mosdns/tailscale-magicdns.yaml" \
	"qname suffix:hs.jmsu.top" \
	"forward_tailscale_magicdns" \
	"bind_to_device" \
	"tailscale0" \
	"/var/etc/mosdns.json" \
	"jq"; do
	grep -q "$expected" "$GATEWAY_INIT" || {
		echo "gateway script missing mosdns compatibility guard: $expected"
		exit 1
	}
done

grep -q '/etc/init.d/tailscale-nikki-guard start' "$GATEWAY_INIT" || {
	echo "gateway script does not re-apply Nikki tailnet bypass guard"
	exit 1
}

grep -q '100.64.0.0/10' "$NIKKI_BOOT_GUARD" || {
	echo "Nikki guard no longer preserves tailnet CIDR"
	exit 1
}

grep -q 'udp://100.100.100.100:53#tailscale0' "$NIKKI_BOOT_GUARD" || {
	echo "Nikki guard no longer binds Quad100 to tailscale0"
	exit 1
}

echo "tailscale LAN-to-tailnet gateway test passed"
