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
PI_MODEL_CATALOG="$ROOT_DIR/files/etc/pi/agent/models.json"
AGENT_RUNTIME_MANIFEST_DIR="$ROOT_DIR/Scripts/node-agent-runtime"
PI_PLAN_MODE_VENDOR_DIR="$AGENT_RUNTIME_MANIFEST_DIR/vendor/pi-plan-mode"

# Default Node.js target version (Node 24 LTS line)
NODE_DEFAULT_VERSION="24.20.0"
NODE_FALLBACK_VERSION="22.23.2"
NODE_VERSION="${NODE_VERSION:-$NODE_DEFAULT_VERSION}"

NODE_MIRROR_UNOFFICIAL="https://unofficial-builds.nodejs.org/download/release"
NODE_MIRROR_GITHUB="${NODE_GITHUB_MIRROR:-https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins}"
PI_FD_VERSION="10.5.0"
PI_FD_RELEASE_BASE_URL="https://github.com/sharkdp/fd/releases/download/v${PI_FD_VERSION}"

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

pi_fd_asset_sha256() {
	case "$1" in
		linux-arm64-musl)
			printf '%s\t%s\n' \
				"fd-v${PI_FD_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
				"d76c4317f7d5dba69f8a2a15856c90c777e7f0dd4e85f0de8c76de6992c374d4"
			;;
		linux-x64-musl)
			printf '%s\t%s\n' \
				"fd-v${PI_FD_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
				"761c72dc8e120d85b22292063be8a796e2eeb20eb3e4f38b8fa2343ccf3514a7"
			;;
		*)
			return 1
			;;
	esac
}

install_pi_search_tools() (
	local node_arch="$1" asset expected_hash actual_hash row tmpdir extracted fd_binary file_info

	row="$(pi_fd_asset_sha256 "$node_arch")" || {
		echo "ERROR: no reviewed Pi fd archive for ${node_arch}" >&2
		return 1
	}
	IFS=$'\t' read -r asset expected_hash <<<"$row"
	[ -n "$asset" ] && [ -n "$expected_hash" ] || {
		echo "ERROR: invalid Pi fd release metadata for ${node_arch}" >&2
		return 1
	}

	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT
	log_info "Downloading checksum-verified Pi fd ${PI_FD_VERSION} for ${node_arch}..."
	retry_cmd 3 10 curl --fail --silent --show-error --location \
		--proto '=https' --tlsv1.2 \
		"${PI_FD_RELEASE_BASE_URL}/${asset}" -o "$tmpdir/$asset"

	actual_hash="$(sha256sum "$tmpdir/$asset" | awk '{print $1}')"
	[ "$actual_hash" = "$expected_hash" ] || {
		echo "ERROR: Pi fd ${PI_FD_VERSION}/${node_arch} SHA256 mismatch" >&2
		return 1
	}

	if tar -tzf "$tmpdir/$asset" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
		echo "ERROR: unsafe path in Pi fd archive $asset" >&2
		return 1
	fi
	mkdir -p "$tmpdir/extracted"
	tar -xzf "$tmpdir/$asset" -C "$tmpdir/extracted" --no-same-owner
	fd_binary="$(find "$tmpdir/extracted" -type f -name fd -print | sed -n '1p')"
	[ -n "$fd_binary" ] || {
		echo "ERROR: verified Pi fd archive has no fd binary" >&2
		return 1
	}
	[ "$(find "$tmpdir/extracted" -type f -name fd -print | wc -l)" -eq 1 ] || {
		echo "ERROR: verified Pi fd archive has multiple fd binaries" >&2
		return 1
	}
	file_info="$(file -b "$fd_binary")"
	case "$node_arch:$file_info" in
		linux-arm64-musl:*ELF*64-bit*ARM*aarch64*) ;;
		linux-x64-musl:*ELF*64-bit*x86-64*) ;;
		*)
			echo "ERROR: Pi fd archive architecture does not match ${node_arch}: $file_info" >&2
			return 1
			;;
	esac
	printf '%s' "$file_info" | grep -Eqi '(statically linked|static-pie linked)' || {
		echo "ERROR: Pi fd binary must be static musl (static or static-pie): $file_info" >&2
		return 1
	}

	install -Dm0755 "$fd_binary" "$SYS_BIN_DIR/fd"
	log_info "Installed verified Pi fd ${PI_FD_VERSION} to /usr/bin/fd; ripgrep is supplied by CONFIG_PACKAGE_ripgrep."
)

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

	log_info "Installing CommandCode, Pi CLI and extensions from package-lock.json..."
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
			--ignore-scripts --os=linux --cpu="$npm_arch" --libc=musl

	[ -d "$staging_dir/node_modules" ] || {
		echo "ERROR: npm ci completed without producing node_modules" >&2
		return 1
	}
	cp -a "$staging_dir/node_modules/." "$NODE_LIB_DIR/"

	prune_foreign_platform_builds "$npm_arch"
	verify_agent_runtime_arch "$npm_arch"

	for bin in pnpm pi cmdc command-code commandcode; do
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

# 只认已知的非 ELF 幻数（PE、Mach-O 64 两种字节序、fat 通用二进制），而不是
# "不是 ELF 就算外来文件"：以后真出现以 .node 结尾的文本桩时，后者会把它误删。
# shellcheck disable=SC2310 # set -e is deliberately relaxed inside this predicate helper
foreign_os_binary() {
	local binary="$1" b0 b1 b2 b3
	[ -f "$binary" ] || return 1
	b0="$(elf_header_byte "$binary" 0)"
	b1="$(elf_header_byte "$binary" 1)"
	b2="$(elf_header_byte "$binary" 2)"
	b3="$(elf_header_byte "$binary" 3)"
	case "$b0:$b1:$b2:$b3" in
		77:90:*:*) return 0 ;;
		207:250:237:254|254:237:250:207|202:254:186:190|190:186:254:202) return 0 ;;
	esac
	return 1
}

# 交叉安装（npm ci --os=linux --cpu=<arch> --libc=musl）会把两类设备上永远加载不了
# 的二进制留在树里，纯粹是体积：
#   1. 非 Linux 平台的预编译产物。pi-tui 与 pnpm 自带的 @reflink 把全平台 prebuild
#      直接打进自己的 tarball，npm 没有可选平台包可以跳过。
#   2. glibc 版预编译产物。npm 的 libc 字段只做提示，不按 --libc 过滤可选依赖，所以
#      koffi 的 linux_<arch>、napi-rs 的 *-linux-<arch>-gnu 和 opentui 无后缀的
#      core-linux-<arch> 都会和 musl 版一起装进来；设备的 node 是 musl 静态链接，
#      这些带 DT_NEEDED libc.so.6 的文件 dlopen 必然失败。
# 对应的 musl 版本（musl_<arch>、*-musl、core-linux-<arch>-musl）全部保留。
prune_foreign_platform_builds() {
	local npm_arch="$1"
	local expected_machine keep_triplet koffi_dir variant gnu_dir
	local module module_machine dropped

	case "$npm_arch" in
		arm64) expected_machine=183; keep_triplet="musl_arm64" ;;
		x64) expected_machine=62; keep_triplet="musl_x64" ;;
		*)
			echo "ERROR: unsupported npm target $npm_arch" >&2
			return 1
			;;
	esac

	for koffi_dir in "$NODE_LIB_DIR"/koffi/build/koffi/*; do
		[ -d "$koffi_dir" ] || continue
		case "$(basename "$koffi_dir")" in
			"$keep_triplet") continue ;;
			*)
				rm -rf -- "$koffi_dir"
				log_info "Pruned koffi build $(basename "$koffi_dir")."
				;;
		esac
	done

	variant=""
	while IFS= read -r variant; do
		case "$(basename "$variant")" in
			"clipboard-linux-${npm_arch}-musl") continue ;;
		esac
		rm -rf -- "$variant"
		log_info "Pruned $(basename "$variant")."
	done < <(find "$NODE_LIB_DIR" \( -type d -name 'clipboard-darwin-*' \
		-o -type d -name 'clipboard-win32-*' -o -type d -name 'clipboard-linux-*' \) -prune -print)

	# 按命名约定清掉其余 glibc 包目录，嵌套副本一并覆盖。
	gnu_dir=""
	while IFS= read -r gnu_dir; do
		[ -n "$gnu_dir" ] || continue
		rm -rf -- "$gnu_dir"
		log_info "Pruned glibc build $(basename "$gnu_dir")."
	done < <(find "$NODE_LIB_DIR" -type d \
		\( -name "*-linux-${npm_arch}-gnu" -o -name "core-linux-${npm_arch}" \) \
		-prune -print)

	# node-pre-gyp 风格的包（msgpackr-extract）把构建机的预编译产物直接放进主包
	# tarball 的 build/Release，没有可选平台包可以让 npm 交叉安装跳过，上面按目录名
	# 的规则也看不到它。所以按文件头逐个判定：不是目标架构的 ELF，或者是 Mach-O/PE，
	# 设备都只会得到 ENOEXEC，留着没有任何作用。
	dropped=0
	while IFS= read -r module; do
		[ -n "$module" ] || continue
		module_machine="$(elf_machine_id "$module" || true)"
		if [ -z "$module_machine" ]; then
			foreign_os_binary "$module" || continue
		else
			[ "$module_machine" != "$expected_machine" ] || continue
		fi
		rm -f -- "$module"
		dropped=$((dropped + 1))
	done < <(find "$NODE_LIB_DIR" -type f -name '*.node' -print)
	[ "$dropped" -eq 0 ] || log_info "Pruned ${dropped} unloadable native module(s)."
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
		   -o -name 'cmdc' -o -name 'command-code' -o -name 'commandcode' \) \
		-size +8k -print)

	log_info "Verified every loadable agent runtime binary targets ${npm_arch}."
}

setup_symlinks() {
	log_info "Configuring binary symlinks..."

	for bin in node npm npx corepack pnpm pi cmdc command-code commandcode; do
		if [ -f "$NODE_BIN_DIR/$bin" ]; then
			chmod +x "$NODE_BIN_DIR/$bin" 2>/dev/null || true
			ln -sf "/opt/node/bin/$bin" "$SYS_BIN_DIR/$bin"
		fi
	done
}

install_vendored_pi_extensions() {
	local target="$NODE_LIB_DIR/pi-plan-mode"

	[ -s "$PI_PLAN_MODE_VENDOR_DIR/plan-mode.ts" ] && \
		[ -s "$PI_PLAN_MODE_VENDOR_DIR/provenance.json" ] && \
		[ -s "$PI_PLAN_MODE_VENDOR_DIR/LICENSE" ] || {
		echo "ERROR: reviewed pi-plan-mode vendor source is incomplete" >&2
		return 1
	}
	rm -rf -- "$target"
	cp -a "$PI_PLAN_MODE_VENDOR_DIR" "$target"
	[ -s "$target/plan-mode.ts" ] || return 1
	log_info "Installed reviewed vendored pi-plan-mode extension."
}

configure_pi_extensions() {
	log_info "Writing default Pi extensions configuration..."

	# WRT-CORE packages the Node runtime before it overlays files/ onto the
	# OpenWrt image tree.  Read the reviewed catalog from the repository, then
	# stage it explicitly so this installer does not depend on a later copy.
	[ -s "$PI_MODEL_CATALOG" ] || {
		echo "ERROR: default Pi model catalog is missing" >&2
		return 1
	}
	install -Dm0644 "$PI_MODEL_CATALOG" "$TARGET_FILES/etc/pi/agent/models.json"
	cp -f "$PI_MODEL_CATALOG" "$PI_CONFIG_DIR/models.json"
	cat >"$PI_CONFIG_DIR/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B",
  "defaultThinkingLevel": "medium",
  "enableInstallTelemetry": false,
  "defaultProjectTrust": "ask",
  "packages": [
    "@aaronkyriesenbach/pi-package-manager",
    "btw-pi",
    "pi-web-search",
    "pi-wechat-assistant"
  ],
  "extensions": [
    "/tmp/agent-runtime-pi-plan-mode.ts"
  ],
  "autoUpdate": false
}
EOF
	cp -f "$PI_CONFIG_DIR/settings.json" "$TARGET_FILES/etc/pi/agent/settings.json"
}

main() {
	prepare_directories

	local node_arch installed_node_version
	node_arch="$(map_node_arch)"
	installed_node_version="$NODE_VERSION"

	if ! download_node_tarball "$node_arch" "$NODE_VERSION"; then
		log_info "Trying fallback Node.js version ${NODE_FALLBACK_VERSION}..."
		installed_node_version="$NODE_FALLBACK_VERSION"
		download_node_tarball "$node_arch" "$NODE_FALLBACK_VERSION" || {
			echo "ERROR: unable to install a checksummed Node.js runtime" >&2
			exit 1
		}
	fi
	mkdir -p "$TARGET_FILES/etc/agent-runtime"
	printf '%s\n' "$installed_node_version" >"$TARGET_FILES/etc/agent-runtime/node-version"

	preinstall_cli_agents_and_extensions "$node_arch"
	install_vendored_pi_extensions
	setup_symlinks
	install_pi_search_tools "$node_arch"
	configure_pi_extensions

	log_info "Checksummed Node.js and locked CLI agent runtime setup complete."
}

main "$@"
