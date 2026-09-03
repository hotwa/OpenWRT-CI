# Upgrades installed on /data shadow the read-only baked runtime in /opt.
export PATH=/data/node/bin:/opt/node/bin:$PATH
export NODE_PATH=/data/node/lib/node_modules:/opt/node/lib/node_modules

# /data is optional during rescue/early boot. Never create cache directories
# below the root overlay merely because a login shell was opened before the
# UUID-backed data mount became ready.
if awk '$2 == "/data" && $1 ~ /^\/dev\// && ($3 == "ext4" || $3 == "f2fs") { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null; then
	export PNPM_HOME=/data/pnpm/bin
	export PNPM_STORE_DIR=/data/pnpm/store
	export NPM_CONFIG_CACHE=/data/npm
	export npm_config_cache=/data/npm
	export NODE_COMPILE_CACHE=/data/node-compile-cache
else
	export PNPM_HOME=/root/.local/share/pnpm
	export PNPM_STORE_DIR=/root/.local/share/pnpm/store
	export NPM_CONFIG_CACHE=/root/.npm
	export npm_config_cache=/root/.npm
	unset NODE_COMPILE_CACHE
fi
