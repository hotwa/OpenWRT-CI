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
AGENT_RUNTIME_MANIFEST_DIR="$ROOT_DIR/Scripts/node-agent-runtime"

# Default Node.js target version (Node 24 LTS line)
NODE_DEFAULT_VERSION="24.20.0"
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

node_archive_sha256() {
	case "$1:$2" in
		24.20.0:linux-arm64-musl)
			echo "2c8c507ccb0f20812d9526ba8ca454b1652aadef68fc8bad06f07fb1122dd1ef"
			;;
		24.20.0:linux-x64-musl)
			echo "9ae1399fef4bd8990e15773ce1327b336a20b9e97d8c7549f4f42ca73c43f562"
			;;
		22.23.2:linux-arm64-musl)
			echo "b7a1a2b1c7c76e47550f17764676939840e0a64b4d04bdd375a4ac14bccaa8d8"
			;;
		22.23.2:linux-x64-musl)
			echo "396e11ee609eb2e5cb990f045c4d037aa47b2c247f3cecb01c5c162e33ffa9af"
			;;
		*)
			return 1
			;;
	esac
}

download_node_tarball() (
	local node_arch="$1"
	local version="$2"
	local archive="node-v${version}-${node_arch}.tar.gz"
	local url_unofficial="${NODE_MIRROR_UNOFFICIAL}/v${version}/${archive}"
	local url_github="${NODE_MIRROR_GITHUB}/${archive}"
	local expected_hash actual_hash extracted_root tmpdir

	expected_hash="$(node_archive_sha256 "$version" "$node_arch")" || {
		echo "ERROR: no reviewed Node.js checksum for v${version}/${node_arch}" >&2
		return 1
	}

	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT
	log_info "Downloading Node.js v${version} for ${node_arch}..."

	if ! retry_cmd 3 10 curl -fsSL "$url_unofficial" -o "$tmpdir/$archive"; then
		log_info "Primary Node.js mirror unavailable; trying the reviewed GitHub mirror..."
		retry_cmd 3 10 curl -fsSL "$url_github" -o "$tmpdir/$archive"
	fi

	actual_hash="$(sha256sum "$tmpdir/$archive" | awk '{print $1}')"
	if [ "$actual_hash" != "$expected_hash" ]; then
		echo "ERROR: Node.js v${version}/${node_arch} SHA256 mismatch" >&2
		echo "ERROR: expected $expected_hash, got $actual_hash" >&2
		return 1
	fi

	mkdir -p "$tmpdir/extracted"
	tar -xzf "$tmpdir/$archive" -C "$tmpdir/extracted"
	extracted_root="$tmpdir/extracted/node-v${version}-${node_arch}"
	[ -x "$extracted_root/bin/node" ] || {
		echo "ERROR: verified Node.js archive has an unexpected layout" >&2
		return 1
	}

	log_info "Installing verified ${archive} to ${NODE_ROOT_DIR}..."
	cp -a "$extracted_root/." "$NODE_ROOT_DIR/"
)

preinstall_cli_agents_and_extensions() (
	local node_arch="$1"
	local npm_arch staging_dir bin

	log_info "Installing OpenCode, Pi CLI, Hermes and extensions from package-lock.json..."
	command -v npm >/dev/null 2>&1 || {
		echo "ERROR: host npm is required for the locked agent runtime install" >&2
		return 1
	}
	[ -f "$AGENT_RUNTIME_MANIFEST_DIR/package.json" ] && \
		[ -f "$AGENT_RUNTIME_MANIFEST_DIR/package-lock.json" ] || {
		echo "ERROR: locked agent runtime manifest is incomplete" >&2
		return 1
	}

	case "$node_arch" in
		linux-arm64-musl) npm_arch="arm64" ;;
		linux-x64-musl) npm_arch="x64" ;;
		*)
			echo "ERROR: unsupported npm target $node_arch" >&2
			return 1
			;;
	esac

	staging_dir="$(mktemp -d)"
	trap 'rm -rf "$staging_dir"' EXIT
	cp "$AGENT_RUNTIME_MANIFEST_DIR/package.json" "$AGENT_RUNTIME_MANIFEST_DIR/package-lock.json" "$staging_dir/"
	npm_config_arch="$npm_arch" \
	npm_config_platform="linux" \
	npm_config_libc="musl" \
		npm ci --prefix "$staging_dir" --omit=dev --no-audit --no-fund \
			--os=linux --cpu="$npm_arch" --libc=musl

	[ -d "$staging_dir/node_modules" ] || {
		echo "ERROR: npm ci completed without producing node_modules" >&2
		return 1
	}
	cp -a "$staging_dir/node_modules/." "$NODE_LIB_DIR/"

	fix_opencode_entrypoint "$npm_arch"
	prune_agent_runtime_deadweight

	for bin in pnpm opencode pi hermes; do
		[ -e "$NODE_LIB_DIR/.bin/$bin" ] || {
			echo "ERROR: locked agent runtime did not install $bin" >&2
			return 1
		}
		ln -sf "../lib/node_modules/.bin/$bin" "$NODE_BIN_DIR/$bin"
	done

)

elf_header_byte() {
	od -An -j "$2" -N1 -tu1 -- "$1" | tr -dc '0-9'
}

# shellcheck disable=SC2310 # set -e is deliberately relaxed inside this predicate helper
elf_machine_id() {
	local binary="$1" magic class data lo hi
	[ -f "$binary" ] || return 1
	magic="$(elf_header_byte "$binary" 0)"
	class="$(elf_header_byte "$binary" 4)"
	data="$(elf_header_byte "$binary" 5)"
	lo="$(elf_header_byte "$binary" 18)"
	hi="$(elf_header_byte "$binary" 19)"
	[ "$magic" = "127" ] && [ "$class" = "2" ] && [ "$data" = "1" ] && \
		[ -n "$lo" ] && [ -n "$hi" ] || return 1
	echo $((lo + hi * 256))
}

# opencode-ai 的 postinstall 在构建 runner 上按 runner 架构把二进制复制成
# bin/opencode.exe，交叉安装时会把 x86-64/glibc 程序烧进 ARM64 固件；平台包
# 目录只在安装期使用，运行入口始终是 opencode-ai/bin/opencode.exe。
fix_opencode_entrypoint() {
	local npm_arch="$1"
	local target="$NODE_LIB_DIR/opencode-ai/bin/opencode.exe"
	local candidates pkg source expected_machine
	local machine interp

	[ -f "$NODE_LIB_DIR/opencode-ai/package.json" ] || {
		echo "ERROR: opencode-ai is missing from the locked agent runtime" >&2
		return 1
	}

	case "$npm_arch" in
		arm64)
			candidates="opencode-linux-arm64-musl"
			expected_machine=183
			;;
		x64)
			candidates="opencode-linux-x64-baseline-musl opencode-linux-x64-musl"
			expected_machine=62
			;;
		*)
			echo "ERROR: unsupported npm target $npm_arch" >&2
			return 1
			;;
	esac

	source=""
	for pkg in $candidates; do
		if [ -f "$NODE_LIB_DIR/$pkg/bin/opencode" ]; then
			source="$NODE_LIB_DIR/$pkg/bin/opencode"
			break
		fi
	done
	[ -n "$source" ] || {
		echo "ERROR: none of the musl opencode packages ($candidates) was installed" >&2
		return 1
	}

	rm -f "$target"
	cp -f "$source" "$target"
	chmod 0755 "$target"
	rm -rf "$NODE_LIB_DIR"/opencode-linux-*

	machine="$(elf_machine_id "$target")" || {
		echo "ERROR: $target is not an ELF64 little-endian executable" >&2
		return 1
	}
	[ "$machine" = "$expected_machine" ] || {
		echo "ERROR: opencode entrypoint is ELF machine $machine, expected $expected_machine for $npm_arch" >&2
		return 1
	}
	interp="$(head -c 8192 "$target" | grep -a -m1 -oE '/lib[a-z0-9_]*/ld-[A-Za-z0-9._-]+' || true)"
	echo "$interp" | grep -q musl || {
		echo "ERROR: opencode entrypoint interpreter is '$interp', expected a musl loader" >&2
		return 1
	}

	log_info "opencode entrypoint now uses the ${npm_arch} musl binary (${interp})."
}

# hermes-agent 发布物内嵌了完整的 monorepo 测试与文档站，设备端既跑不到也用不到。
prune_agent_runtime_deadweight() {
	local path
	for path in \
		"$NODE_LIB_DIR/hermes-agent/runtime/hermes-agent/tests" \
		"$NODE_LIB_DIR/hermes-agent/runtime/hermes-agent/website"
	do
		if [ -d "$path" ]; then
			rm -rf "$path"
			log_info "Pruned ${path#"$NODE_LIB_DIR"/}."
		else
			warn "expected prunable directory is missing: $path"
		fi
	done
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

# Mutable runtime paths are published only after /data is a verified mountpoint.
# Services that do not load login profiles must source this file explicitly or
# pass the same values through procd_set_param env.
[ -r /tmp/uv-env.sh ] && . /tmp/uv-env.sh
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
			echo "ERROR: unable to install a checksummed Node.js runtime" >&2
			exit 1
		}
	fi

	preinstall_cli_agents_and_extensions "$node_arch"
	setup_symlinks
	configure_pi_extensions
	configure_profiles

	log_info "Checksummed Node.js and locked CLI agent runtime setup complete."
}

main "$@"
