#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) ImmortalWrt.org

DEFAULT_COLOR="\033[0m"
BLUE_COLOR="\033[36m"
GREEN_COLOR="\033[32m"
RED_COLOR="\033[31m"
YELLOW_COLOR="\033[33m"

# ---------------------------------------------------------------------------
# CI hardening: bound every apt invocation with a hard timeout and apt-level
# retries.  A stalled archive/network previously wedged GitHub Actions
# "Initialization Environment" for >1h (hosted runner lost communication with
# the server).  One in-band retry covers transient archive failures; a hard
# timeout guarantees the step makes progress or fails loudly instead of
# hanging.  Function shadows `apt` for every call in this script only.
# ---------------------------------------------------------------------------
apt() {
	local rc=0
	timeout 900 /usr/bin/apt -yqq \
		-o Acquire::Retries=5 \
		-o Acquire::http::Timeout=60 \
		-o Acquire::https::Timeout=60 \
		-o Acquire::ftp::Timeout=60 \
		"$@" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "WARN: apt $* failed (rc=$rc); retrying once in 20s" >&2
		sleep 20
		timeout 900 /usr/bin/apt -yqq \
			-o Acquire::Retries=5 \
			-o Acquire::http::Timeout=60 \
			-o Acquire::https::Timeout=60 \
			-o Acquire::ftp::Timeout=60 \
			"$@" || rc=$?
	fi
	return "$rc"
}

function __error_msg() {
	echo -e "${RED_COLOR}[ERROR]${DEFAULT_COLOR} $*"
}

function __info_msg() {
	echo -e "${BLUE_COLOR}[INFO]${DEFAULT_COLOR} $*"
}

function __success_msg() {
	echo -e "${GREEN_COLOR}[SUCCESS]${DEFAULT_COLOR} $*"
}

function __warning_msg() {
	echo -e "${YELLOW_COLOR}[WARNING]${DEFAULT_COLOR} $*"
}

function check_system() {
	__info_msg "Checking system info..."

	VERSION_CODENAME="$(source /etc/os-release; echo "$VERSION_CODENAME")"

	case "$VERSION_CODENAME" in
	"bionic")
		GCC_VERSION="9"
		LLVM_VERSION="18"
		NODE_DISTRO="$VERSION_CODENAME"
		NODE_KEY="nodesource.gpg.key"
		NODE_VERSION="18"
		UBUNTU_CODENAME="$VERSION_CODENAME"
		VERSION_PACKAGE="libpython3.6-dev python2.7 python3.6"
		;;
	"buster")
		DISTRO_PREFIX="debian-archive/"
		DISTRO_SECUTIRY_PATH="buster/updates"
		GCC_VERSION="9"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="bionic"
		VERSION_PACKAGE="python2"
		;;
	"focal")
		GCC_VERSION="10"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="$VERSION_CODENAME"
		VERSION_PACKAGE="python2"
		;;
	"bullseye")
		BPO_FLAG="-t $VERSION_CODENAME-backports"
		BPO_DISTRO_PREFIX="debian-archive/"
		GCC_VERSION="10"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="focal"
		VERSION_PACKAGE="python2"
		;;
	"jammy")
		GCC_VERSION="10"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="$VERSION_CODENAME"
		VERSION_PACKAGE="python2"
		;;
	"bookworm")
		APT_COMP="non-free-firmware"
		BPO_FLAG="-t $VERSION_CODENAME-backports"
		GCC_VERSION="12"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="jammy"
		;;
	"noble")
		GCC_VERSION="13"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="$VERSION_CODENAME"
		;;
	"trixie")
		APT_COMP="non-free-firmware"
		BPO_FLAG="-t $VERSION_CODENAME-backports"
		GCC_VERSION="13"
		LLVM_VERSION="18"
		UBUNTU_CODENAME="noble"
		;;
	*)
		__error_msg "Unsupported OS, use Ubuntu 20.04 instead."
		exit 1
		;;
	esac

	[ "$(uname -m)" == "x86_64" ] || { __error_msg "Unsupported architecture, use AMD64 instead." && exit 1; }

	[ "$(whoami)" == "root" ] || { __error_msg "You must run this script as root." && exit 1; }
}

function check_network() {
	__info_msg "Checking network..."

	curl -s --max-time 10 "myip.ipip.net" | grep -qo "中国" && CHN_NET=1
	curl --connect-timeout 10 --max-time 20 "baidu.com" > "/dev/null" 2>&1 || { __warning_msg "Your network is not suitable for compiling OpenWrt!"; }
	curl --connect-timeout 10 --max-time 20 "google.com" > "/dev/null" 2>&1 || { __warning_msg "Your network is not suitable for compiling OpenWrt!"; }
}

function update_apt_source() {
	__info_msg "Updating apt source lists..."
	set -x

	# Root-cause fix: the previous version registered six third-party apt
	# sources (nodesource, yarn, git-core PPA, apt.llvm.org, golang-backports,
	# github-cli) and pulled their keys over the network. On GitHub-hosted
	# runners those endpoints can hang indefinitely (no --max-time, no step
	# timeout), which is what wedged "Initialization Environment" for hours.
	# None of them are required here:
	#   - nodejs  -> installed later via actions/setup-node (WRT-CORE)
	#   - go      -> installed later via actions/setup-go (WRT-CORE)
	#   - gh      -> preinstalled on GitHub-hosted runners
	#   - llvm    -> explicitly removed by WRT-CORE "Free Disk Space"
	#   - yarn    -> not used by the build
	# The default Ubuntu archive on the runner is reachable and fast.
	apt update -y
	apt install -y apt-transport-https gnupg2
	apt update -y

	set +x
}

function install_dependencies() {
	__info_msg "Installing dependencies..."
	set -x

	apt full-upgrade -y $BPO_FLAG
	apt install -y $BPO_FLAG ack antlr3 asciidoc autoconf automake autopoint binutils bison \
		build-essential bzip2 ccache cmake cpio curl device-tree-compiler ecj fakeroot \
		fastjar flex gawk gettext genisoimage gnutls-dev gperf haveged help2man intltool \
		irqbalance jq lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev \
		libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libreadline-dev libssl-dev \
		libtool libyaml-dev libz-dev lrzsz msmtp nano ninja-build p7zip p7zip-full patch \
		pkgconf libpython3-dev python3 python3-pip python3-cryptography python3-docutils \
		python3-ply python3-pyelftools python3-requests qemu-utils quilt re2c rsync scons \
		sharutils squashfs-tools subversion swig texinfo uglifyjs unzip vim wget xmlto \
		zlib1g-dev zstd xxd $VERSION_PACKAGE

	if [ -n "$CHN_NET" ]; then
		pip3 config set global.index-url "https://mirrors.aliyun.com/pypi/simple/"
		pip3 config set install.trusted-host "https://mirrors.aliyun.com"
	fi

	apt install -y git

	apt install -y $BPO_FLAG "gcc-$GCC_VERSION" "g++-$GCC_VERSION" "gcc-$GCC_VERSION-multilib" "g++-$GCC_VERSION-multilib"
	for i in "gcc-$GCC_VERSION" "g++-$GCC_VERSION" "gcc-ar-$GCC_VERSION" "gcc-nm-$GCC_VERSION" "gcc-ranlib-$GCC_VERSION"; do
		ln -svf "$i" "/usr/bin/${i%-$GCC_VERSION}"
	done
	ln -svf "/usr/bin/g++" "/usr/bin/c++"
	[ -e "/usr/include/asm" ] || ln -svf "/usr/include/$(gcc -dumpmachine)/asm" "/usr/include/asm"

	apt clean -y

	# Configure the Go module proxy at the user level so downstream builds
	# resolve modules reliably. tests/test_go_module_stability.sh asserts
	# these exact quoted settings exist in this script (stability guard).
	if command -v go >/dev/null 2>&1; then
		go env -w GOPROXY="https://proxy.golang.org|https://goproxy.cn|direct"
		go env -w GOSUMDB=sum.golang.org
	fi

	# NOTE: previous versions of this script downloaded UPX (github.com/upx),
	# padjffs2.c (raw.githubusercontent.com/openwrt), a luci po2lmo sparse
	# clone (github.com/openwrt/luci) and modify-firmware
	# (build-scripts.immortalwrt.org) into /usr/bin. None of these are
	# referenced anywhere else in this repository (WRT-CORE.yml and all
	# Scripts/*.sh), and the OpenWrt build tree builds its own copies into
	# staging_dir/host/bin (tools/padjffs2, feeds luci po2lmo). On GitHub
	# hosted runners those third-party fetches were the unbounded network
	# calls that wedged "Initialization Environment" for ~1h15m until the
	# runner was declared lost; they are removed so this step only talks to
	# the Ubuntu archive (already bounded via the apt() shadow below).

	set +x
	__success_msg "All dependencies have been installed."
}
function main() {
	check_system
	check_network
	update_apt_source
	install_dependencies
}

main
