# Source the non-secret runtime selection made at boot.  data-runtime writes
# this file atomically and only emits fixed KEY=value records.
DATA_RUNTIME_ENV_FILE=/var/run/data-runtime.env
if [ -f "$DATA_RUNTIME_ENV_FILE" ] && [ ! -L "$DATA_RUNTIME_ENV_FILE" ] && [ -r "$DATA_RUNTIME_ENV_FILE" ]; then
	. "$DATA_RUNTIME_ENV_FILE"
	case "$DATA_RUNTIME_STATE:$DATA_RUNTIME_ROOT" in
		persistent:/data|fallback:/root)
			export DATA_RUNTIME_STATE DATA_RUNTIME_ROOT XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME TMPDIR
			export PNPM_HOME PNPM_STORE_DIR NPM_CONFIG_CACHE npm_config_cache COREPACK_HOME
			export UV_CACHE_DIR UV_TOOL_DIR UV_PYTHON_INSTALL_DIR PI_HOME ;;
		emergency:/tmp)
			unset XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME PNPM_HOME PNPM_STORE_DIR
			unset NPM_CONFIG_CACHE npm_config_cache COREPACK_HOME UV_CACHE_DIR UV_TOOL_DIR UV_PYTHON_INSTALL_DIR PI_HOME
			export DATA_RUNTIME_STATE DATA_RUNTIME_ROOT TMPDIR ;;
		*) unset DATA_RUNTIME_STATE DATA_RUNTIME_ROOT ;;
	esac
fi

# A degraded root-overlay status means /etc and /root may be backed by RAM.
# Never source this diagnostic file or interpolate its contents into the
# terminal: the login warning is deliberately fixed text.
ROOT_OVERLAY_STATUS_FILE=/var/run/root-overlay.status
if [ -t 1 ] && [ "$(id -u 2>/dev/null)" = 0 ] && \
	[ -f "$ROOT_OVERLAY_STATUS_FILE" ] && [ ! -L "$ROOT_OVERLAY_STATUS_FILE" ] && \
	grep -Fqx 'state=degraded' "$ROOT_OVERLAY_STATUS_FILE" 2>/dev/null; then
	printf '\n\033[1;31mWARNING: persistent root overlay is unavailable or could not be verified.\033[0m\n'
	printf '\033[1;31mChanges under /etc and /root may be lost after reboot. See /var/run/root-overlay.status.\033[0m\n\n'
fi
unset ROOT_OVERLAY_STATUS_FILE
