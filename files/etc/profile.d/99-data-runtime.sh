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
