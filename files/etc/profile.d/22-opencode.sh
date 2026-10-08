# opencode runtime: prefer /data installation, fall back to nothing (wrapper
# triggers install on demand). The wrapper at /usr/bin/opencode handles this.
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
case "${DATA_RUNTIME_STATE:-}:${DATA_RUNTIME_ROOT:-}" in
	persistent:/data)
		export XDG_CONFIG_HOME=/data/opencode/config
		export XDG_CACHE_HOME=/data/opencode/cache
		export XDG_DATA_HOME=/data/opencode/data
		export XDG_STATE_HOME=/data/opencode/state
		;;
	*)
		# /data not ready; don't set XDG paths (use defaults in /root)
		;;
esac
