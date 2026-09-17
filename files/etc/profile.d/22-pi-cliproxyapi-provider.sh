# CliProxyAPI provider defaults for interactive Pi sessions.  The API key, if
# injected by CI, is a root-only data file and is never evaluated as shell.
CLIPROXYAPI_BASE_URL="http://192.168.11.159:8317/v1"
cliproxyapi_base_file="/etc/pi/agent/cliproxyapi-base-url"
if [ -f "$cliproxyapi_base_file" ] && [ ! -L "$cliproxyapi_base_file" ]; then
	IFS= read -r CLIPROXYAPI_BASE_URL <"$cliproxyapi_base_file" || true
fi
export CLIPROXYAPI_BASE_URL

cliproxyapi_key_file="/etc/pi/agent/cliproxyapi-api-key"
if [ -f "$cliproxyapi_key_file" ] && [ ! -L "$cliproxyapi_key_file" ]; then
	IFS= read -r CLIPROXYAPI_API_KEY <"$cliproxyapi_key_file" || true
	export CLIPROXYAPI_API_KEY
fi
unset cliproxyapi_base_file cliproxyapi_key_file
