#!/usr/bin/env bash
# Guarded firmware fleet preflight and deployment helper. It is intentionally
# inert without an explicit workflow dispatch and never obtains build secrets.
set -euo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-hotwa/OpenWRT-CI}"

die() {
	echo "ERROR: firmware fleet deploy: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
Usage:
  FirmwareFleetDeploy.sh validate-inventory --inventory PATH
  FirmwareFleetDeploy.sh validate-run --run-id ID
  FirmwareFleetDeploy.sh preflight --inventory PATH --target ID|all --ssh-config PATH
  FirmwareFleetDeploy.sh fetch-verify --inventory PATH --target ID|all --run-id ID --output DIR
  FirmwareFleetDeploy.sh upgrade --inventory PATH --target ID|all --images-dir DIR --ssh-config PATH
EOF
	exit 2
}

need_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

valid_target_id() {
	[[ "$1" =~ ^[a-z0-9]+-[0-9]{1,3}$ ]]
}

valid_fqdn() {
	[[ "$1" =~ ^[a-z0-9-]+\.hs\.jmsu\.top$ ]]
}

valid_board() {
	case "$1" in
		jdcloud,re-cs-07|jdcloud,re-cs-02|jdcloud,re-ss-01) return 0 ;;
		*) return 1 ;;
	esac
}

validate_inventory() {
	local inventory="$1" suffix count record id short board cidr fqdn config device third
	local -A seen_ids=() seen_fqdns=() seen_cidrs=()

	need_command jq
	[ -f "$inventory" ] || die "inventory is missing: $inventory"
	jq -e '
		type == "object" and .schema_version == 1 and
		(.magicdns_suffix | type == "string" and length > 0) and
		(.devices | type == "array" and length > 0)
	' "$inventory" >/dev/null || die "inventory schema is invalid"
	suffix="$(jq -r '.magicdns_suffix' "$inventory")"
	[ "$suffix" = 'hs.jmsu.top' ] || die "inventory MagicDNS suffix is not the approved Tailnet suffix"
	count="$(jq '.devices | length' "$inventory")"

	while IFS= read -r record; do
		id="$(jq -r '.id // empty' <<<"$record")"
		short="$(jq -r '.model_short // empty' <<<"$record")"
		board="$(jq -r '.board // empty' <<<"$record")"
		cidr="$(jq -r '.lan_cidr // empty' <<<"$record")"
		fqdn="$(jq -r '.magicdns // empty' <<<"$record")"
		config="$(jq -r '.artifact_config // empty' <<<"$record")"
		device="$(jq -r '.artifact_device // empty' <<<"$record")"
		valid_target_id "$id" || die "invalid device id: $id"
		[[ "$short" =~ ^[a-z0-9]+$ ]] || die "invalid model_short for $id"
		valid_board "$board" || die "unapproved board for $id: $board"
		[[ "$cidr" =~ ^192\.168\.([0-9]{1,3})\.0/24$ ]] || die "invalid /24 LAN CIDR for $id: $cidr"
		third="${BASH_REMATCH[1]}"
		(( third <= 255 )) || die "LAN third octet is invalid for $id"
		[ "$id" = "$short-$third" ] || die "device id must equal model-short plus LAN third octet: $id"
		valid_fqdn "$fqdn" || die "invalid MagicDNS name for $id: $fqdn"
		[ "$fqdn" = "$id.$suffix" ] || die "MagicDNS name does not match id for $id"
		[[ "$config" =~ ^IPQ60XX-RE-(CS-07-NOWIFI|CS-02|SS-01)$ ]] || die "invalid artifact config for $id"
		[[ "$device" =~ ^jdcloud_re-(cs-07|cs-02|ss-01)$ ]] || die "invalid artifact device for $id"
		[ -z "${seen_ids[$id]:-}" ] || die "duplicate device id: $id"
		[ -z "${seen_fqdns[$fqdn]:-}" ] || die "duplicate MagicDNS name: $fqdn"
		[ -z "${seen_cidrs[$cidr]:-}" ] || die "overlapping LAN CIDR: $cidr"
		seen_ids["$id"]=1
		seen_fqdns["$fqdn"]=1
		seen_cidrs["$cidr"]=1
	done < <(jq -c '.devices[]' "$inventory")

	[ "${#seen_ids[@]}" -eq "$count" ] || die "inventory iteration did not cover every device"
	echo "fleet inventory validated: $count device(s)"
}

records_for_target() {
	local inventory="$1" target="$2" count
	validate_inventory "$inventory" >/dev/null
	if [ "$target" = all ]; then
		jq -c '.devices[]' "$inventory"
		return 0
	fi
	valid_target_id "$target" || die "target must be a registry ID or all"
	count="$(jq --arg id "$target" '[.devices[] | select(.id == $id)] | length' "$inventory")"
	[ "$count" = 1 ] || die "target is not registered: $target"
	jq -c --arg id "$target" '.devices[] | select(.id == $id)' "$inventory"
}

validate_run() {
	local run_id="$1" run_json conclusion branch
	[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || die "run id must be numeric"
	need_command gh
	run_json="$(gh api "repos/$REPOSITORY/actions/runs/$run_id")" || die "cannot read workflow run $run_id"
	conclusion="$(jq -r '.conclusion // empty' <<<"$run_json")"
	branch="$(jq -r '.head_branch // empty' <<<"$run_json")"
	[ "$conclusion" = success ] || die "source workflow run is not successful: $run_id"
	[ "$branch" = main ] || die "source workflow run is not from main: $branch"
	echo "source run validated: $run_id"
}

remote_exec() {
	local ssh_config="$1" host="$2"
	shift 2
	ssh -F "$ssh_config" -o BatchMode=yes "root@$host" "$@"
}

preflight_record() {
	local record="$1" ssh_config="$2" id board cidr fqdn output remote_board remote_cidr remote_pref remote_dns
	id="$(jq -r '.id' <<<"$record")"
	board="$(jq -r '.board' <<<"$record")"
	cidr="$(jq -r '.lan_cidr' <<<"$record")"
	fqdn="$(jq -r '.magicdns' <<<"$record")"
	valid_fqdn "$fqdn" || die "unsafe registry FQDN: $fqdn"

	output="$(remote_exec "$ssh_config" "$fqdn" 'set -eu
board="$(ubus call system board | jsonfilter -e "@.board_name")"
status="$(ubus call network.interface.lan status)"
lan_ip="$(printf "%s" "$status" | jsonfilter -e "@[\"ipv4-address\"][0].address")"
lan_mask="$(printf "%s" "$status" | jsonfilter -e "@[\"ipv4-address\"][0].mask")"
pref="$(tailscale debug prefs | jsonfilter -e "@.Hostname")"
dns="$(tailscale status --json | jsonfilter -e "@.Self.DNSName")"
dns="${dns%.}"
/usr/sbin/openwrt-ci-health --require data,wan,tailscale,magicdns,nikki >/dev/null
printf "%s\t%s/%s\t%s\t%s\n" "$board" "$lan_ip" "$lan_mask" "$pref" "$dns"')" || die "cannot complete read-only preflight for $id ($fqdn)"
	IFS=$'\t' read -r remote_board remote_cidr remote_pref remote_dns <<<"$output"
	[ "$remote_board" = "$board" ] || die "$id board mismatch: expected $board, got $remote_board"
	[ "$remote_cidr" = "$cidr" ] || die "$id active LAN mismatch: expected $cidr, got $remote_cidr"
	[ "$remote_pref" = "$id" ] || die "$id local Tailscale preference mismatch: got $remote_pref"
	[ "$remote_dns" = "$fqdn" ] || die "$id Headscale MagicDNS is not reconciled: got $remote_dns"
	echo "preflight passed: $id ($fqdn)"
}

preflight() {
	local inventory="$1" target="$2" ssh_config="$3" record
	[ -f "$ssh_config" ] || die "SSH config is missing"
	while IFS= read -r record; do
		preflight_record "$record" "$ssh_config"
	done < <(records_for_target "$inventory" "$target")
}

safe_artifact_members() {
	local archive="$1" member
	while IFS= read -r member; do
		case "$member" in
			''|/*|../*|*/../*|*/..|.) die "unsafe artifact archive member: $member" ;;
		esac
	done < <(unzip -Z1 "$archive")
}

verify_extracted_artifact() {
	local artifact_dir="$1" config="$2" device="$3"
	local expected listed sorted_listed line digest filename image_count image
	[ -d "$artifact_dir" ] || die "artifact extraction directory is missing"
	[ -f "$artifact_dir/SHA256SUMS" ] || die "artifact SHA256SUMS is missing"
	[ -f "$artifact_dir/metadata.json" ] || die "artifact metadata is missing"
	[ -z "$(find "$artifact_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] || die "artifact has nested or non-regular files"
	[ -z "$(find "$artifact_dir" -mindepth 2 -print -quit)" ] || die "artifact has nested files"
	expected="$(mktemp)"
	listed="$(mktemp)"
	sorted_listed="$(mktemp)"
	trap 'rm -f "$expected" "$listed" "$sorted_listed"' RETURN
	find "$artifact_dir" -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort > "$expected"
	while IFS= read -r line || [ -n "$line" ]; do
		digest="${line%%  *}"
		filename="${line#"$digest  "}"
		[ "$line" = "$digest  $filename" ] || die "malformed SHA256SUMS line"
		[[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || die "invalid SHA256SUMS digest"
		case "$filename" in ''|-*|.|..|*/*|*\\*) die "unsafe SHA256SUMS filename" ;; esac
		grep -Fxq -- "$filename" "$listed" && die "duplicate SHA256SUMS filename"
		printf '%s\n' "$filename" >> "$listed"
	done < "$artifact_dir/SHA256SUMS"
	LC_ALL=C sort "$listed" > "$sorted_listed"
	cmp -s "$expected" "$sorted_listed" || die "SHA256SUMS does not cover exactly the artifact payload"
	(cd "$artifact_dir" && sha256sum --check --strict -- SHA256SUMS >/dev/null) || die "artifact checksum verification failed"
	jq -e --arg config "$config" --arg device "$device" '
		(.config == $config) and (.required_device == $device) and
		(.source_commit | type == "string" and test("^[0-9a-f]{40}$"))
	' "$artifact_dir/metadata.json" >/dev/null || die "artifact metadata does not match registry"
	image_count="$(find "$artifact_dir" -maxdepth 1 -type f -name "*${device}*sysupgrade*.bin" | wc -l | tr -d ' ')"
	[ "$image_count" = 1 ] || die "artifact must contain exactly one $device sysupgrade image"
	image="$(find "$artifact_dir" -maxdepth 1 -type f -name "*${device}*sysupgrade*.bin" -print -quit)"
	printf '%s' "$image"
}

fetch_verify() {
	local inventory="$1" target="$2" run_id="$3" output_dir="$4"
	local record id config device artifact_json artifact_count artifact_id archive extracted image
	validate_run "$run_id" >/dev/null
	need_command unzip
	mkdir -p "$output_dir"
	: > "$output_dir/images.tsv"
	while IFS= read -r record; do
		id="$(jq -r '.id' <<<"$record")"
		config="$(jq -r '.artifact_config' <<<"$record")"
		device="$(jq -r '.artifact_device' <<<"$record")"
		artifact_json="$(gh api --paginate "repos/$REPOSITORY/actions/runs/$run_id/artifacts")"
		artifact_count="$(jq --arg config "$config" '[.artifacts[] | select(.expired == false and (.name | contains($config)))] | length' <<<"$artifact_json")"
		[ "$artifact_count" = 1 ] || die "$id requires exactly one unexpired artifact for $config, found $artifact_count"
		artifact_id="$(jq -r --arg config "$config" '.artifacts[] | select(.expired == false and (.name | contains($config))) | .id' <<<"$artifact_json")"
		archive="$output_dir/$id.zip"
		gh api "repos/$REPOSITORY/actions/artifacts/$artifact_id/zip" > "$archive" || die "failed to download artifact for $id"
		[ -s "$archive" ] || die "downloaded artifact is empty for $id"
		safe_artifact_members "$archive"
		extracted="$output_dir/$id"
		mkdir -p "$extracted"
		unzip -q "$archive" -d "$extracted"
		image="$(verify_extracted_artifact "$extracted" "$config" "$device")"
		printf '%s\t%s\n' "$id" "$image" >> "$output_dir/images.tsv"
		echo "artifact verified: $id"
	done < <(records_for_target "$inventory" "$target")
}

upgrade_record() {
	local record="$1" ssh_config="$2" image="$3"
	local id fqdn image_name remote_path local_sha remote_sha boot_before boot_after attempt=0
	id="$(jq -r '.id' <<<"$record")"
	fqdn="$(jq -r '.magicdns' <<<"$record")"
	[ -f "$image" ] || die "verified image is missing for $id"
	image_name="$(basename "$image")"
	[[ "$image_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe image filename"
	remote_path="/data/firmware-cd/incoming/$image_name"

	preflight_record "$record" "$ssh_config"
	remote_exec "$ssh_config" "$fqdn" 'install -d -m 700 /data/firmware-cd/incoming'
	RSYNC_RSH="ssh -F $ssh_config -o BatchMode=yes" rsync --partial --checksum --protect-args "$image" "root@$fqdn:$remote_path"
	local_sha="$(sha256sum "$image" | awk '{print $1}')"
	remote_sha="$(remote_exec "$ssh_config" "$fqdn" "sha256sum '$remote_path' | awk '{print \$1}'")"
	[ "$local_sha" = "$remote_sha" ] || die "$id remote image checksum mismatch"
	remote_exec "$ssh_config" "$fqdn" "sysupgrade -T '$remote_path'"
	boot_before="$(remote_exec "$ssh_config" "$fqdn" cat /proc/sys/kernel/random/boot_id)"
	echo "sysupgrade starting: $id"
	set +e
	remote_exec "$ssh_config" "$fqdn" "sysupgrade -c '$remote_path'"
	set -e

	while [ "$attempt" -lt 60 ]; do
		if boot_after="$(remote_exec "$ssh_config" "$fqdn" cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; then
			if [ "$boot_after" != "$boot_before" ] && preflight_record "$record" "$ssh_config" >/dev/null; then
				echo "post-boot acceptance passed: $id"
				return 0
			fi
		fi
		attempt=$((attempt + 1))
		sleep 10
	done
	die "post-boot acceptance timed out for $id"
}

upgrade() {
	local inventory="$1" target="$2" images_dir="$3" ssh_config="$4" record id image
	[ -f "$images_dir/images.tsv" ] || die "verified image manifest is missing"
	while IFS= read -r record; do
		id="$(jq -r '.id' <<<"$record")"
		image="$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' "$images_dir/images.tsv")"
		[ -n "$image" ] || die "verified image is missing from manifest for $id"
		upgrade_record "$record" "$ssh_config" "$image"
	done < <(records_for_target "$inventory" "$target")
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	command="${1:-}"
	shift || true
	case "$command" in
		validate-inventory)
			[ "${1:-}" = --inventory ] && [ -n "${2:-}" ] || usage
			validate_inventory "$2"
			;;
		validate-run)
			[ "${1:-}" = --run-id ] && [ -n "${2:-}" ] || usage
			validate_run "$2"
			;;
		preflight)
			[ "${1:-}" = --inventory ] && inventory="${2:-}" && [ "${3:-}" = --target ] && target="${4:-}" && [ "${5:-}" = --ssh-config ] && ssh_config="${6:-}" || usage
			preflight "$inventory" "$target" "$ssh_config"
			;;
		fetch-verify)
			[ "${1:-}" = --inventory ] && inventory="${2:-}" && [ "${3:-}" = --target ] && target="${4:-}" && [ "${5:-}" = --run-id ] && run_id="${6:-}" && [ "${7:-}" = --output ] && output_dir="${8:-}" || usage
			fetch_verify "$inventory" "$target" "$run_id" "$output_dir"
			;;
		upgrade)
			[ "${1:-}" = --inventory ] && inventory="${2:-}" && [ "${3:-}" = --target ] && target="${4:-}" && [ "${5:-}" = --images-dir ] && images_dir="${6:-}" && [ "${7:-}" = --ssh-config ] && ssh_config="${8:-}" || usage
			upgrade "$inventory" "$target" "$images_dir" "$ssh_config"
			;;
		*) usage ;;
	esac
fi
