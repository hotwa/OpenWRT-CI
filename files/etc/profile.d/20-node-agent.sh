# Upgrades installed on /data shadow the read-only baked runtime in /opt.
export PATH=/data/node/bin:/opt/node/bin:$PATH
export PNPM_HOME=/data/pnpm/bin
export PNPM_STORE_DIR=/data/pnpm/store
export npm_config_cache=/data/npm
export NODE_PATH=/data/node/lib/node_modules:/opt/node/lib/node_modules
