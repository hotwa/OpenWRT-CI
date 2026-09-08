#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) ImmortalWrt.org

DEFAULT_COLOR="\033[0m"
BLUE_COLOR="\033[36m"
GREEN_COLOR="\033[32m"
RED_COLOR="\033[31m"
YELLOW_COLOR="\033[33m"

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

	if TMP_DIR="$(mktemp -d)"; then
		pushd "$TMP_DIR"
	else
		__error_msg "Failed to create a tmp directory."
		exit 1
	fi

	UPX_REV="5.0.2"
	curl -fLO "https://github.com/upx/upx/releases/download/v${UPX_REV}/upx-$UPX_REV-amd64_linux.tar.xz"
	tar -Jxf "upx-$UPX_REV-amd64_linux.tar.xz"
	rm -rf "/usr/bin/upx" "/usr/bin/upx-ucl"
	cp -fp "upx-$UPX_REV-amd64_linux/upx" "/usr/bin/upx-ucl"
	chmod 0755 "/usr/bin/upx-ucl"
	ln -svf "/usr/bin/upx-ucl" "/usr/bin/upx"

	curl -fLO "https://raw.githubusercontent.com/openwrt/openwrt/d06b68fe83ebb969baa64335779045d80bc41f89/tools/padjffs2/src/padjffs2.c"
	gcc -Wall -Werror -o "padjffs2" "padjffs2.c"
	strip "padjffs2"
	rm -rf "padjffs2.c" "/usr/bin/padjffs2"
	cp -fp "padjffs2" "/usr/bin/padjffs2"

	git clone --filter=blob:none --no-checkout "https://github.com/openwrt/luci.git" "po2lmo"
	pushd "po2lmo"
	git config core.sparseCheckout true
	echo "modules/luci-base/src" >> ".git/info/sparse-checkout"
	git checkout
	cd "modules/luci-base/src"
	make po2lmo
	strip "po2lmo"
	rm -rf "/usr/bin/po2lmo"
	cp -fp "po2lmo" "/usr/bin/po2lmo"
	popd

	curl -fL "https://build-scripts.immortalwrt.org/modify-firmware.sh" -o "/usr/bin/modify-firmware"
	chmod 0755 "/usr/bin/modify-firmware"

	popd
	rm -rf "$TMP_DIR"

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
