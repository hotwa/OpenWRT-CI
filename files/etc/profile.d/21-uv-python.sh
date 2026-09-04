#!/bin/sh

# Prefer a signed data generation when available; /opt remains the immutable
# firmware fallback.  uv's interpreter/caches are writable only below /data.
[ -r /var/run/data-runtime.env ] && [ ! -L /var/run/data-runtime.env ] && . /var/run/data-runtime.env
UV_RUNTIME_ROOT=/opt/uv
if [ "${DATA_RUNTIME_STATE:-}" = persistent ] && [ "${DATA_RUNTIME_ROOT:-}" = /data ] && [ -x /data/agent-runtime/current/uv/uv ]; then
	UV_RUNTIME_ROOT=/data/agent-runtime/current/uv
fi
if [ -x "$UV_RUNTIME_ROOT/uv" ]; then
	export PATH="$UV_RUNTIME_ROOT:$PATH"
	export UV_PYTHON_INSTALL_MIRROR="file://$UV_RUNTIME_ROOT/python-mirror"
	# data-runtime.env already provides the verified cache and interpreter paths.
fi
unset UV_RUNTIME_ROOT
