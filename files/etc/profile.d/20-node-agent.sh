# 99-data-runtime.sh is intentionally last for interactive shells; consume its
# generated contract here too because this profile must make its choice first.
[ -r /var/run/data-runtime.env ] && [ ! -L /var/run/data-runtime.env ] && . /var/run/data-runtime.env

# Only a verified /data mount shadows the read-only baked runtime in /opt.
if [ "${DATA_RUNTIME_STATE:-}" = persistent ] && [ "${DATA_RUNTIME_ROOT:-}" = /data ]; then
	export PATH=/data/node/bin:/opt/node/bin:$PATH
	export NODE_PATH=/data/node/lib/node_modules:/opt/node/lib/node_modules
else
	export PATH=/opt/node/bin:$PATH
	export NODE_PATH=/opt/node/lib/node_modules
fi

# /data is optional during rescue/early boot. Never create cache directories
# below the root overlay merely because a login shell was opened before the
# UUID-backed data mount became ready.
case "${DATA_RUNTIME_STATE:-}:${DATA_RUNTIME_ROOT:-}" in
	persistent:/data)
		export PNPM_HOME PNPM_STORE_DIR NPM_CONFIG_CACHE npm_config_cache
		export NODE_COMPILE_CACHE=/data/cache/node-compile-cache
		;;
	fallback:/root)
		export PNPM_HOME PNPM_STORE_DIR NPM_CONFIG_CACHE npm_config_cache
		unset NODE_COMPILE_CACHE
		;;
	*)
		unset PNPM_HOME PNPM_STORE_DIR NPM_CONFIG_CACHE npm_config_cache NODE_COMPILE_CACHE
		;;
esac
