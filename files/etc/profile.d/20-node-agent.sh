# Upgrades installed on /data shadow the read-only baked runtime in /opt.
export PATH=/data/node/bin:/opt/node/bin:$PATH
export PNPM_HOME=/data/node/bin
export NODE_PATH=/data/node/lib/node_modules:/opt/node/lib/node_modules
# OpenCode/DCP use the musl OpenTUI backend.  Do not place this in uv's shared
# environment: Hermes and Python consumers must not inherit a Node UI switch.
export OPENTUI_LIBC=musl

# Mutable runtime paths are published only after /data is a verified mountpoint.
# Services that do not load login profiles must source this file explicitly or
# pass the same values through procd_set_param env.
[ -r /tmp/uv-env.sh ] && . /tmp/uv-env.sh
