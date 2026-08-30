#!/bin/sh

# Prefer a signed data generation when available; /opt remains the immutable
# firmware fallback.  uv's interpreter/caches are writable only below /data.
UV_RUNTIME_ROOT=/opt/uv
if [ -x /data/agent-runtime/current/uv/uv ]; then
	UV_RUNTIME_ROOT=/data/agent-runtime/current/uv
fi
if [ -x "$UV_RUNTIME_ROOT/uv" ]; then
	export PATH="$UV_RUNTIME_ROOT:$PATH"
	export UV_PYTHON_INSTALL_MIRROR="file://$UV_RUNTIME_ROOT/python-mirror"
	if [ -d /data/uv ] && [ ! -L /data/uv ]; then
		export UV_CACHE_DIR=/data/uv/cache
		export UV_PYTHON_INSTALL_DIR=/data/uv/python
	fi
fi
unset UV_RUNTIME_ROOT
