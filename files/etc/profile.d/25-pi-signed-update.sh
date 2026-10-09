# This separate profile survives upgrades that retain an older 20-node-agent.sh.
# Pi and its extensions are immutable parts of one signed runtime generation.
pi() {
	if [ "${1:-}" = update ]; then
		shift
		case "${1:-}" in
			''|--extensions|--extension)
				[ "$#" -le 1 ] || { printf 'Unsupported Pi update arguments.\n' >&2; return 2; }
				printf 'Checking signed Pi and extension runtime generation...\n' >&2
				"${PI_RUNTIME_UPDATE_BIN:-/usr/sbin/agent-runtime-auto-upgrade}"
				return $?
				;;
		esac
	fi
	command pi "$@"
}
