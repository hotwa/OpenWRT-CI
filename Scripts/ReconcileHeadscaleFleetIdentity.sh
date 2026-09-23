#!/usr/bin/env bash
# Run on the Headscale controller (or a trusted admin host with its local CLI
# configuration). It has no router credentials and is dry-run by default.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$ROOT_DIR/Config/firmware-fleet.json"
APPLY=false

die() {
	echo "ERROR: Headscale identity reconcile: $*" >&2
	exit 1
}

usage() {
	echo "Usage: $0 [--inventory PATH] [--apply]" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--inventory) INVENTORY="${2:-}"; shift 2 ;;
		--apply) APPLY=true; shift ;;
		*) usage ;;
	esac
done

command -v headscale >/dev/null 2>&1 || die "headscale CLI is unavailable"
command -v jq >/dev/null 2>&1 || die "jq is unavailable"
bash "$ROOT_DIR/Scripts/FirmwareFleetDeploy.sh" validate-inventory --inventory "$INVENTORY" >/dev/null

nodes="$(headscale nodes list --output json)" || die "cannot list Headscale nodes"
nodes="$(jq -ce 'if type == "array" then . elif (.nodes | type) == "array" then .nodes else error("unexpected nodes JSON") end' <<<"$nodes")" || die "Headscale nodes output is not JSON"

while IFS= read -r record; do
	id="$(jq -r '.id' <<<"$record")"
	model="$(jq -r '.model | ascii_downcase' <<<"$record")"
	model="${model// /-}"
	model="${model,,}"
	cidr="$(jq -r '.lan_cidr' <<<"$record")"
	third="$(cut -d. -f3 <<<"$cidr")"
	legacy_one="openwrt-${model}-${third}"
	legacy_two="${model}-s${third}"
	candidates="$(jq -c --arg target "$id" --arg old1 "$legacy_one" --arg old2 "$legacy_two" '
		[.[] | select((.givenName // .given_name // .name // "") as $name |
			$name == $target or $name == $old1 or $name == $old2 or
			($name | test("^" + $target + "-[0-9]+$")))]
	' <<<"$nodes")"
	count="$(jq 'length' <<<"$candidates")"
	[ "$count" -le 1 ] || die "$id has multiple candidate Headscale nodes; refusing to choose one"
	[ "$count" = 1 ] || { echo "no controller node matched $id; skipped"; continue; }
	node="$(jq -c '.[0]' <<<"$candidates")"
	node_id="$(jq -r '.id // empty' <<<"$node")"
	current="$(jq -r '.givenName // .given_name // .name // empty' <<<"$node")"
	[ -n "$node_id" ] && [ -n "$current" ] || die "$id candidate is missing a node id or name"
	jq -e --arg cidr "$cidr" 'tojson | contains($cidr)' <<<"$node" >/dev/null ||
		die "$id candidate does not advertise the registered LAN CIDR $cidr"
	owners="$(jq --arg target "$id" '[.[] | select((.givenName // .given_name // .name // "") == $target)] | length' <<<"$nodes")"
	[ "$owners" = 0 ] || [ "$current" = "$id" ] || die "$id is already owned by another Headscale node"
	if [ "$current" = "$id" ]; then
		echo "already reconciled: $id (node $node_id)"
		continue
	fi
	echo "rename planned: node $node_id $current -> $id"
	if [ "$APPLY" = true ]; then
		headscale nodes rename -i "$node_id" "$id"
		echo "renamed: node $node_id -> $id"
	fi
done < <(jq -c '.devices[]' "$INVENTORY")
