#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILES="${1:-${ROOT_DIR}/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"

NODE_ROOT_DIR="$TARGET_FILES/opt/node"
NODE_BIN_DIR="$NODE_ROOT_DIR/bin"
NODE_LIB_DIR="$NODE_ROOT_DIR/lib/node_modules"
SYS_BIN_DIR="$TARGET_FILES/usr/bin"
PROFILE_DIR="$TARGET_FILES/etc/profile.d"
PI_CONFIG_DIR="$TARGET_FILES/root/.pi/agent"

# Default Node.js target version (Node 24 LTS line)
NODE_DEFAULT_VERSION="24.13.1"
NODE_FALLBACK_VERSION="22.23.2"
NODE_VERSION="${NODE_VERSION:-$NODE_DEFAULT_VERSION}"

NODE_MIRROR_UNOFFICIAL="https://unofficial-builds.nodejs.org/download/release"
NODE_MIRROR_GITHUB="${NODE_GITHUB_MIRROR:-https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins}"

warn() {
	echo "WARN: $*" >&2
}

log_info() {
	echo "INFO: $*"
}

config_file() {
	if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
		echo "$ROOT_DIR/Config/${WRT_CONFIG}.txt"
	fi
}

map_node_arch() {
	case "${NODE_TARGET_ARCH:-}" in
		linux-arm64-musl|linux-x64-musl)
			echo "$NODE_TARGET_ARCH"
			return 0
			;;
	esac

	case "${WRT_ARCH:-}" in
		*x86_64*|x86_64)
			echo "linux-x64-musl"
			return 0
			;;
		*aarch64*|aarch64|*armv8*|armv8|*ipq60*|*ipq807*|*filogic*)
			echo "linux-arm64-musl"
			return 0
			;;
	esac

	local cfg
	cfg="$(config_file || true)"
	if [ -n "$cfg" ]; then
		if grep -q '^CONFIG_TARGET_x86_64=y$' "$cfg"; then
			echo "linux-x64-musl"
			return 0
		fi

		if grep -Eq '^CONFIG_TARGET_(qualcommax|mediatek)=y$' "$cfg" || \
			grep -Eq '^CONFIG_TARGET_(mediatek_filogic|rockchip_armv8)=y$' "$cfg"; then
			echo "linux-arm64-musl"
			return 0
		fi
	fi

	case "${WRT_TARGET:-}" in
		x86)
			echo "linux-x64-musl"
			return 0
			;;
		qualcommax|mediatek|rockchip)
			echo "linux-arm64-musl"
			return 0
			;;
	esac

	echo "linux-arm64-musl"
}

prepare_directories() {
	mkdir -p \
		"$NODE_BIN_DIR" \
		"$NODE_LIB_DIR" \
		"$SYS_BIN_DIR" \
		"$PROFILE_DIR" \
		"$PI_CONFIG_DIR"
}

download_node_tarball() {
	local node_arch="$1"
	local version="$2"
	local archive="node-v${version}-${node_arch}.tar.gz"
	local url_unofficial="${NODE_MIRROR_UNOFFICIAL}/v${version}/${archive}"
	local url_github="${NODE_MIRROR_GITHUB}/${archive}"
	local tmpdir

	tmpdir="$(mktemp -d)"
	log_info "Downloading Node.js v${version} for ${node_arch}..."

	if retry_cmd 3 10 curl -fsSL "$url_unofficial" -o "$tmpdir/$archive" || \
	   retry_cmd 3 10 curl -fsSL "$url_github" -o "$tmpdir/$archive"; then
		log_info "Extracting ${archive} to ${NODE_ROOT_DIR}..."
		tar -xzf "$tmpdir/$archive" --strip-components=1 -C "$NODE_ROOT_DIR"
		rm -rf "$tmpdir"
		return 0
	fi

	rm -rf "$tmpdir"
	warn "Failed to download Node.js v${version} for ${node_arch}"
	return 1
}

preinstall_cli_agents_and_extensions() {
	log_info "Pre-installing OpenCode, Pi CLI, and extensions..."

	local packages=(
		"pnpm@latest"
		"opencode-ai@latest"
		"@tarquinen/opencode-dcp@latest"
		"@mohak34/opencode-notifier@latest"
		"opencode-conductor-plugin@latest"
		"@earendil-works/pi-coding-agent@latest"
		"@aaronkyriesenbach/pi-package-manager@latest"
		"btw-pi@latest"
		"pi-plan-mode@latest"
		"pi-web-search@latest"
		"pi-wechat-assistant@latest"
		"hermes-agent@latest"
	)

	# If host has npm, install packages into the target node_modules prefix
	if command -v npm >/dev/null 2>&1; then
		log_info "Running npm install for global agent packages..."
		npm install --prefix "$NODE_ROOT_DIR" -g "${packages[@]}" --no-audit --no-fund || {
			warn "Host npm install encountered warnings/errors, continuing with binary links..."
		}
	else
		log_info "Host npm not found in runner, setting up wrapper binaries..."
	fi
}

setup_symlinks() {
	log_info "Configuring binary symlinks..."

	for bin in node npm npx corepack pnpm opencode pi hermes; do
		if [ -f "$NODE_BIN_DIR/$bin" ]; then
			chmod +x "$NODE_BIN_DIR/$bin" 2>/dev/null || true
			ln -sf "/opt/node/bin/$bin" "$SYS_BIN_DIR/$bin"
		fi
	done
}

configure_pi_extensions() {
	log_info "Writing default Pi extensions configuration..."

	cat >"$PI_CONFIG_DIR/settings.json" <<'EOF'
{
  "packages": [
    "@aaronkyriesenbach/pi-package-manager",
    "btw-pi",
    "pi-plan-mode",
    "pi-web-search",
    "pi-wechat-assistant"
  ],
  "autoUpdate": false
}
EOF
}

configure_profiles() {
	log_info "Writing profile environment and SSH login check scripts..."

	cat >"$PROFILE_DIR/20-node-agent.sh" <<'EOF'
export PATH=/opt/node/bin:$PATH
export PNPM_HOME=/opt/node/bin
export NODE_PATH=/opt/node/lib/node_modules
EOF

	cat >"$PROFILE_DIR/30-agent-update-check.sh" <<'EOF'
#!/bin/sh
# Non-blocking SSH login check for OpenCode & Pi agent CLI updates (24h cache)
[ -t 1 ] || return 0
[ "$USER" = "root" ] || return 0

CACHE_FILE="/tmp/.agent_update_cache"
NOW=$(date +%s 2>/dev/null || echo 0)
CACHE_TTL=86400

print_agent_status() {
	local node_v oc_v pi_v
	node_v=$(/opt/node/bin/node -v 2>/dev/null || echo "not installed")
	oc_v=$(/opt/node/bin/opencode --version 2>/dev/null || echo "installed")
	pi_v=$(/opt/node/bin/pi --version 2>/dev/null || echo "installed")

	printf "\n\033[1;36m┌──────────────────────────────────────────────────────────────┐\033[0m\n"
	printf "\033[1;36m│\033[0m \033[1;32m🤖 OpenWrt AI Agent CLI Status (Multica / OpenCode / Pi)\033[0m     \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  • Node.js:  %-48s \033[1;36m│\033[0m\n" "$node_v"
	printf "\033[1;36m│\033[0m  • OpenCode: %-48s \033[1;36m│\033[0m\n" "$oc_v"
	printf "\033[1;36m│\033[0m  • Pi CLI:   %-48s \033[1;36m│\033[0m\n" "$pi_v"
	printf "\033[1;36m│\033[0m                                                              \033[1;36m│\033[0m\n"
	printf "\033[1;36m│\033[0m  💡 To upgrade all CLI agents: \033[1;33mpnpm update -g --latest\033[0m       \033[1;36m│\033[0m\n"
	printf "\033[1;36m└──────────────────────────────────────────────────────────────┘\033[0m\n\n"
}

if [ -f "$CACHE_FILE" ]; then
	LAST_CHECK=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
	if [ $((NOW - LAST_CHECK)) -lt "$CACHE_TTL" ]; then
		print_agent_status
		return 0
	fi
fi

touch "$CACHE_FILE" 2>/dev/null || true
print_agent_status
EOF

	chmod 0755 "$PROFILE_DIR/20-node-agent.sh" "$PROFILE_DIR/30-agent-update-check.sh" 2>/dev/null || true
}

main() {
	prepare_directories

	local node_arch
	node_arch="$(map_node_arch)"

	if ! download_node_tarball "$node_arch" "$NODE_VERSION"; then
		log_info "Trying fallback Node.js version ${NODE_FALLBACK_VERSION}..."
		download_node_tarball "$node_arch" "$NODE_FALLBACK_VERSION" || {
			warn "Unable to fetch pre-compiled Node.js binary; continuing build"
		}
	fi

	preinstall_cli_agents_and_extensions
	setup_symlinks
	configure_pi_extensions
	configure_profiles

	log_info "Node.js 24 LTS and CLI agent runtime setup complete."
}

main "$@"