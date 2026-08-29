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
	prune_foreign_platform_builds "$npm_arch"
	verify_agent_runtime_arch "$npm_arch"
	write_agent_runtime_policy

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

# hermes-agent 的 npm 桥接包在 postinstall 里为“安装机”准备整套独立 Python 运行
# 时。CI runner 是 x86_64/glibc，所以 runtime/python、venv 和 .uv_bin 全是宿主机
# 架构的二进制，venv 的 shebang 还指向安装结束时已被删除的 mktemp 目录。设备上是
# arm64/musl，这约 160MB 永远跑不起来，只能整体剔除，由 /etc/init.d/hermes-runtime
# 在设备上用原生 uv 重新生成。
prune_agent_runtime_deadweight() {
	local hermes_dir="$NODE_LIB_DIR/hermes-agent"
	local path

	for path in \
		"$hermes_dir/runtime/hermes-agent/tests" \
		"$hermes_dir/runtime/hermes-agent/website" \
		"$hermes_dir/runtime/hermes-agent/venv" \
		"$hermes_dir/runtime/python" \
		"$hermes_dir/.uv_bin"
	do
		if [ -e "$path" ]; then
			rm -rf -- "$path"
			log_info "Pruned ${path#"$NODE_LIB_DIR"/}."
		else
			warn "expected prunable path is missing: $path"
		fi
	done

	# A marker left over from the runner would make a later 'npm rebuild
	# hermes-agent' believe the baked runtime already matches the device.
	rm -f -- "$hermes_dir/.hermes-agent-runtime.json"
}

# koffi 与 @mariozechner/clipboard 会把全平台预编译产物一起发布，设备只会加载本机
# 架构那一份，其余（含被 npm 交叉安装漏进来的嵌套副本）都是纯体积。
prune_foreign_platform_builds() {
	local npm_arch="$1"
	local keep_a keep_b koffi_dir variant

	case "$npm_arch" in
		arm64) keep_a="linux_arm64"; keep_b="musl_arm64" ;;
		x64) keep_a="linux_x64"; keep_b="musl_x64" ;;
		*)
			echo "ERROR: unsupported npm target $npm_arch" >&2
			return 1
			;;
	esac

	for koffi_dir in "$NODE_LIB_DIR"/koffi/build/koffi/*; do
		[ -d "$koffi_dir" ] || continue
		case "$(basename "$koffi_dir")" in
			"$keep_a"|"$keep_b") continue ;;
			*)
				rm -rf -- "$koffi_dir"
				log_info "Pruned koffi build $(basename "$koffi_dir")."
				;;
		esac
	done

	variant=""
	while IFS= read -r variant; do
		case "$(basename "$variant")" in
			"clipboard-linux-${npm_arch}-gnu"|"clipboard-linux-${npm_arch}-musl") continue ;;
		esac
		rm -rf -- "$variant"
		log_info "Pruned $(basename "$variant")."
	done < <(find "$NODE_LIB_DIR" \( -type d -name 'clipboard-darwin-*' \
		-o -type d -name 'clipboard-win32-*' -o -type d -name 'clipboard-linux-*' \) -prune -print)
}

# Only files that Node or Python would actually load are probed; scanning the
# whole 2 GB tree byte by byte would dominate the build for no extra signal.
verify_agent_runtime_arch() {
	local npm_arch="$1"
	local expected_machine binary machine

	case "$npm_arch" in
		arm64) expected_machine=183 ;;
		x64) expected_machine=62 ;;
		*)
			echo "ERROR: unsupported npm target $npm_arch" >&2
			return 1
			;;
	esac

	while IFS= read -r binary; do
		[ -n "$binary" ] || continue
		machine="$(elf_machine_id "$binary" || true)"
		[ -z "$machine" ] || [ "$machine" = "$expected_machine" ] || {
			echo "ERROR: agent runtime contains a foreign-arch ELF: ${binary#"$NODE_LIB_DIR"/} (ELF machine $machine, target $npm_arch)" >&2
			return 1
		}
	done < <(find "$NODE_LIB_DIR" -type f \
		\( -name '*.node' -o -name '*.so' -o -name '*.so.*' \
		   -o -name 'uv' -o -name 'python3.*' -o -name 'opencode*' -o -name 'hermes' \) \
		-size +8k -print)

	log_info "Verified every loadable agent runtime binary targets ${npm_arch}."
}

# The device-side provisioner must install exactly the audited npm release, so
# the pinned version is recorded at build time instead of floating on device.
write_agent_runtime_policy() {
	local hermes_version
	local policy_dir="$TARGET_FILES/etc/agent-runtime"

	hermes_version="$(sed -n 's/^[[:space:]]*"version": *"\([^"]*\)".*/\1/p' \
		"$NODE_LIB_DIR/hermes-agent/package.json" | head -n1)"
	[[ "$hermes_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		echo "ERROR: unable to read the pinned hermes-agent version from the locked runtime" >&2
		return 1
	}

	mkdir -p "$policy_dir"
	cat >"$policy_dir/agent-update.env" <<EOF
# Generated by Scripts/fetch_node_runtime.sh. Do not edit on device.
HERMES_NPM_PACKAGE=hermes-agent
HERMES_NPM_VERSION=$hermes_version
EOF
	log_info "Recorded hermes-agent $hermes_version for device-side provisioning."
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

	log_info "Checksummed Node.js and locked CLI agent runtime setup complete."
}

main "$@"
