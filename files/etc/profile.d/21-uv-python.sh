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

	# Expose uv-managed Python's bin directory on PATH so `python3` resolves
	# directly even when /usr/local/bin/python3 symlink is not yet provisioned.
	# Silently skip if /data is not ready (uv python find may fail).
	uv_py_bin=""
	if uv_py_path="$(uv python find 3.13 2>/dev/null)"; then
		[ -n "$uv_py_path" ] && [ -x "$uv_py_path" ] && uv_py_bin="$(dirname "$uv_py_path")"
	fi
	if [ -z "$uv_py_bin" ]; then
		if uv_py_path="$(uv python find 2>/dev/null)"; then
			[ -n "$uv_py_path" ] && [ -x "$uv_py_path" ] && uv_py_bin="$(dirname "$uv_py_path")"
		fi
	fi
	if [ -n "$uv_py_bin" ]; then
		case ":$PATH:" in
			*":$uv_py_bin:"*) ;;
			*) export PATH="$uv_py_bin:$PATH" ;;
		esac
	fi
fi
unset UV_RUNTIME_ROOT
