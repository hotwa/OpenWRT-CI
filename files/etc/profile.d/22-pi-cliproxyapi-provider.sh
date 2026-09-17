# CliProxyAPI provider defaults for interactive Pi sessions.  The API key, if
# injected by CI, is a root-only data file and is never evaluated as shell.
export CLIPROXYAPI_BASE_URL="http://192.168.11.159:8317"

cliproxyapi_key_file="/etc/pi/agent/cliproxyapi-api-key"
if [ -f "$cliproxyapi_key_file" ] && [ ! -L "$cliproxyapi_key_file" ]; then
	IFS= read -r CLIPROXYAPI_API_KEY <"$cliproxyapi_key_file" || true
	export CLIPROXYAPI_API_KEY
fi
unset cliproxyapi_key_file
