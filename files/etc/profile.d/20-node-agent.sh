export PATH=/opt/node/bin:$PATH
export PNPM_HOME=/opt/node/bin
export NODE_PATH=/opt/node/lib/node_modules

# Mutable runtime paths are published only after /data is a verified mountpoint.
# Services that do not load login profiles must source this file explicitly or
# pass the same values through procd_set_param env.
[ -r /tmp/uv-env.sh ] && . /tmp/uv-env.sh
