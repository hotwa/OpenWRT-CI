#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

. "$(dirname "$(realpath "$0")")/retry.sh"

PKG_PATH="$GITHUB_WORKSPACE/$WRT_DIR/package/"

preload_nikki_geodata() {
	mkdir -p "$GITHUB_WORKSPACE/files/etc/nikki/run"

	retry_cmd 5 15 curl -fL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat" -o "$GITHUB_WORKSPACE/files/etc/nikki/run/geoip.dat"
	retry_cmd 5 15 curl -fL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" -o "$GITHUB_WORKSPACE/files/etc/nikki/run/geosite.dat"
	retry_cmd 5 15 curl -fL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" -o "$GITHUB_WORKSPACE/files/etc/nikki/run/geoip.metadb"

	cd "$PKG_PATH" && echo "nikki geodata has been preloaded into files/etc/nikki/run!"
}

preload_nikki_geodata

patch_wrtbak_proxy_url() {
	WRTBAK_S3="./luci-app-wrtbak/root/usr/lib/wrtbak/remote_s3.sh"
	[ -f "$WRTBAK_S3" ] || return 0

	if grep -q 'wrtbak_main_option proxy_url' "$WRTBAK_S3" && grep -q 'WRTBAK_S3_FORCE_DIRECT' "$WRTBAK_S3"; then
		cd "$PKG_PATH" && echo "wrtbak S3 proxy_url support is already present!"
		return 0
	fi

	python3 - "$WRTBAK_S3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_plain = '''wrtbak_s3_rclone() {
	wrtbak_config=$1
	shift
	rclone --config "$wrtbak_config" "$@"
}'''
old_proxy = '''wrtbak_s3_rclone() {
	wrtbak_config=$1
	shift
	wrtbak_proxy_url=$(wrtbak_main_option proxy_url "")
	if [ -n "$wrtbak_proxy_url" ]; then
		HTTP_PROXY="$wrtbak_proxy_url" HTTPS_PROXY="$wrtbak_proxy_url" ALL_PROXY="$wrtbak_proxy_url" \\
		http_proxy="$wrtbak_proxy_url" https_proxy="$wrtbak_proxy_url" all_proxy="$wrtbak_proxy_url" \\
			rclone --config "$wrtbak_config" "$@"
	else
		rclone --config "$wrtbak_config" "$@"
	fi
}'''
new = '''wrtbak_s3_rclone() {
	wrtbak_config=$1
	shift
	case "${WRTBAK_S3_FORCE_DIRECT:-0}" in
		1|true|yes|on|direct)
			wrtbak_proxy_url=
			;;
		*)
			wrtbak_proxy_url=$(wrtbak_main_option proxy_url "")
			;;
	esac
	if [ -n "$wrtbak_proxy_url" ]; then
		HTTP_PROXY="$wrtbak_proxy_url" \\
		HTTPS_PROXY="$wrtbak_proxy_url" \\
		ALL_PROXY="$wrtbak_proxy_url" \\
		http_proxy="$wrtbak_proxy_url" \\
		https_proxy="$wrtbak_proxy_url" \\
		all_proxy="$wrtbak_proxy_url" \\
		NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}" \\
		no_proxy="${no_proxy:-localhost,127.0.0.1,::1}" \\
			rclone --config "$wrtbak_config" "$@"
	else
		rclone --config "$wrtbak_config" "$@"
	fi
}'''
if old_plain in text:
	text = text.replace(old_plain, new, 1)
elif old_proxy in text:
	text = text.replace(old_proxy, new, 1)
else:
	raise SystemExit("wrtbak S3 rclone function shape changed")
path.write_text(text)
PY

	grep -q 'wrtbak_main_option proxy_url' "$WRTBAK_S3" || {
		echo "ERROR: failed to patch wrtbak S3 proxy_url support" >&2
		exit 1
	}
	grep -q 'WRTBAK_S3_FORCE_DIRECT' "$WRTBAK_S3" || {
		echo "ERROR: failed to patch wrtbak firstboot direct-R2 support" >&2
		exit 1
	}

	cd "$PKG_PATH" && echo "wrtbak S3 proxy_url support has been patched!"
}

patch_wrtbak_proxy_url

# 修复 procd 源码镜像 404：优先使用 GitHub 镜像仓库。
PROCD_MAKEFILE="../package/system/procd/Makefile"
if [ -f "$PROCD_MAKEFILE" ]; then
	sed -i 's#^PKG_SOURCE_URL:=.*procd\.git$#PKG_SOURCE_URL:=https://github.com/openwrt/procd.git#g' "$PROCD_MAKEFILE"
	if grep -q '^PKG_SOURCE_URL:=https://github.com/openwrt/procd.git$' "$PROCD_MAKEFILE"; then
		cd "$PKG_PATH" && echo "procd source url has been switched to GitHub mirror!"
	else
		echo "WARNING: procd mirror sed did not match, original URL retained" >&2
	fi
fi

# 修复 gettext-full 0.24.1 host 编译失败：上游源码树用 gnulib stable-202501 重新
# bootstrap，其 string-desc.h 将 sd_new_addr 的非常量分支改为 rw_string_desc_t，
# 与 0.24.1 的 msgl-iconv.c 返回类型不兼容。对齐 immortalwrt 上游提交
# 0237b9a06b（"gettext-full: update to 0.24.2"，含 DEPENDS 构建顺序修正），
# 将 gettext-full 升级到 0.24.2。
GETTEXT_MAKEFILE="./libs/gettext-full/Makefile"
GETTEXT_OLD_HASH="6164ec7aa61653ac9cdfb41d5c2344563b21f707da1562712e48715f1d2052a6"
GETTEXT_NEW_HASH="fcc0187f597aef6bc5bc95c629db1126315beb196b20570eaec6a4941850f7c5"
if [ -f "$GETTEXT_MAKEFILE" ]; then
	if grep -q '^PKG_VERSION:=0\.24\.2$' "$GETTEXT_MAKEFILE"; then
		cd "$PKG_PATH" && echo "gettext-full is already at 0.24.2!"
	elif grep -q '^PKG_VERSION:=0\.24\.1$' "$GETTEXT_MAKEFILE" && \
		grep -q "^PKG_HASH:=$GETTEXT_OLD_HASH\$" "$GETTEXT_MAKEFILE"; then
		sed -i 's/^PKG_VERSION:=0\.24\.1$/PKG_VERSION:=0.24.2/' "$GETTEXT_MAKEFILE"
		sed -i "s/^PKG_HASH:=$GETTEXT_OLD_HASH\$/PKG_HASH:=$GETTEXT_NEW_HASH/" "$GETTEXT_MAKEFILE"
		sed -i 's|^  URL:=https://www.gnu.org/software/gettext/$|  URL:=https://www.gnu.org/software/gettext/\n  DEPENDS:=+libunistring +libxml2|' "$GETTEXT_MAKEFILE"
		grep -q '^PKG_VERSION:=0\.24\.2$' "$GETTEXT_MAKEFILE" && \
			grep -q "^PKG_HASH:=$GETTEXT_NEW_HASH\$" "$GETTEXT_MAKEFILE" || {
			echo "ERROR: failed to bump gettext-full to 0.24.2" >&2
			exit 1
		}
		cd "$PKG_PATH" && echo "gettext-full has been bumped to 0.24.2!"
	fi
fi

# 修复 gnulib stable-202501 缺少 rw_string_desc_t：gettext 0.24.2 的 msgl-iconv.h
# 引用该类型，但仅在 gnulib stable-202507 中定义。对齐 immortalwrt 上游提交
# 837f5eaae2（"tools: gnulib: update to branch stable-202507"）。
GNULIB_MAKEFILE="../tools/gnulib/Makefile"
GNULIB_OLD_VER="a3151d456d6919c9066b54dc6f680452168165cf"
GNULIB_NEW_VER="b22f5a3037712a3c957a03071ce0b219cef4d65b"
GNULIB_OLD_HASH="b695d96e915ecd6c4551436f417cb2c0879aef4ef6318721c8d5cc86cb44ba9d"
GNULIB_NEW_HASH="d1423a784794e3e08bd03b397544821ece257aa748566386bd97219d1edf98d5"
if [ -f "$GNULIB_MAKEFILE" ]; then
	if grep -q "^PKG_SOURCE_VERSION:=$GNULIB_NEW_VER" "$GNULIB_MAKEFILE"; then
		cd "$PKG_PATH" && echo "gnulib is already at stable-202507!"
	elif grep -q "^PKG_SOURCE_VERSION:=$GNULIB_OLD_VER" "$GNULIB_MAKEFILE" && \
		grep -q "^PKG_MIRROR_HASH:=$GNULIB_OLD_HASH\$" "$GNULIB_MAKEFILE"; then
		sed -i 's/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=2026-07-04/' "$GNULIB_MAKEFILE"
		sed -i "s/^PKG_SOURCE_VERSION:=$GNULIB_OLD_VER/PKG_SOURCE_VERSION:=$GNULIB_NEW_VER/" "$GNULIB_MAKEFILE"
		sed -i "s/^PKG_MIRROR_HASH:=$GNULIB_OLD_HASH\$/PKG_MIRROR_HASH:=$GNULIB_NEW_HASH/" "$GNULIB_MAKEFILE"
		GNULIB_PATCH_DIR="../tools/gnulib/patches"
		if [ -d "$GNULIB_PATCH_DIR" ]; then
			rm -f "$GNULIB_PATCH_DIR"/640-mem-hash-map.patch \
			      "$GNULIB_PATCH_DIR"/645-next-prime.patch \
			      "$GNULIB_PATCH_DIR"/646-hashcode-string.patch \
			      "$GNULIB_PATCH_DIR"/647-hashkey-string.patch \
			      "$GNULIB_PATCH_DIR"/650-package-version.patch \
			      "$GNULIB_PATCH_DIR"/651-package-version-simplify.patch \
			      "$GNULIB_PATCH_DIR"/652-package-version-simplify-further.patch \
			      "$GNULIB_PATCH_DIR"/653-package-version-warning.patch \
			      "$GNULIB_PATCH_DIR"/660-version-stamp.patch \
			      "$GNULIB_PATCH_DIR"/689-vc-mtime.patch \
			      "$GNULIB_PATCH_DIR"/755-clean-temp-hashkey.patch \
			      "$GNULIB_PATCH_DIR"/795-string-desc-rename-functions.patch \
			      "$GNULIB_PATCH_DIR"/796-vc-mtime-less-read.patch \
			      "$GNULIB_PATCH_DIR"/797-vc-mtime-add-api.patch \
			      "$GNULIB_PATCH_DIR"/798-vc-mtime-add-api.patch \
			      "$GNULIB_PATCH_DIR"/799-vc-mtime-old-git.patch \
			      "$GNULIB_PATCH_DIR"/900-str_startswith-module.patch \
			      "$GNULIB_PATCH_DIR"/901-str_endswith-module.patch
		fi
		grep -q "^PKG_SOURCE_VERSION:=$GNULIB_NEW_VER" "$GNULIB_MAKEFILE" && \
			grep -q "^PKG_MIRROR_HASH:=$GNULIB_NEW_HASH\$" "$GNULIB_MAKEFILE" || {
			echo "ERROR: failed to bump gnulib to stable-202507" >&2
			exit 1
		}
		cd "$PKG_PATH" && echo "gnulib has been bumped to stable-202507!"
	fi
fi

# 修复 sbwml/luci-app-mosdns 的 ES6+ 语法与 LuCI jsmin 的兼容问题。
MOSDNS_ROOT="./luci-app-mosdns"
if [ -d "$MOSDNS_ROOT" ]; then
	"$GITHUB_WORKSPACE/Scripts/patch_mosdns_jsmin_compat.sh" "$MOSDNS_ROOT"
	cd "$PKG_PATH" && echo "mosdns jsmin compatibility has been fixed!"
fi

#预置HomeProxy数据
HP_DIR=""
for d in "$PKG_PATH"/*homeproxy*; do
	[ -d "$d" ] && HP_DIR="$d" && break
done
if [ -n "$HP_DIR" ]; then
	echo " "

	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	retry_cmd 5 15 git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" ./$HP_RULE/ || {
		echo "ERROR: failed to clone surge-rules for homeproxy" >&2
		exit 1
	}
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd $PKG_PATH && echo "homeproxy date has been updated!"
fi

#修改argon主题字体和颜色
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "

	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" \
		"$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"

	echo "theme-argon has been fixed!"
fi

#修改aurora菜单式样
if [ -d *"luci-app-aurora-config"* ]; then
	echo " "

	cd ./luci-app-aurora-config/

	find ./root/ -type f -name "*aurora" -exec sed -i "s/nav_submenu_type '.*'/nav_submenu_type 'boxed-dropdown'/g" {} +

	cd $PKG_PATH && echo "theme-aurora has been fixed!"
fi

#修改qca-nss-drv启动顺序
NSS_DRV="../feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
if [ -f "$NSS_DRV" ]; then
	echo " "

	sed -i 's/START=.*/START=85/g' $NSS_DRV

	cd $PKG_PATH && echo "qca-nss-drv has been fixed!"
fi

#修改qca-nss-pbuf启动顺序
NSS_PBUF="./kernel/mac80211/files/qca-nss-pbuf.init"
if [ -f "$NSS_PBUF" ]; then
	echo " "

	sed -i 's/START=.*/START=86/g' $NSS_PBUF

	cd $PKG_PATH && echo "qca-nss-pbuf has been fixed!"
fi

#修复Rust编译失败
FEEDS_PACKAGES="$PKG_PATH/../feeds/packages"
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"

	if grep -q 'ci-llvm=false' "$RUST_FILE"; then
		echo "rust has been fixed!"
	else
		echo "WARNING: rust ci-llvm sed did not match" >&2
	fi
fi

#修复DiskMan编译失败
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	echo " "

	sed -i '/ntfs-3g-utils /d' $DM_FILE

	cd $PKG_PATH && echo "diskman has been fixed!"
fi

#修复luci-app-netspeedtest相关问题
if [ -d *"luci-app-netspeedtest"* ]; then
	echo " "

	cd ./luci-app-netspeedtest/

	grep -q '^exit 0$' ./netspeedtest/files/99_netspeedtest.defaults || \
		sed -i '$a\exit 0' ./netspeedtest/files/99_netspeedtest.defaults
	sed -i 's/ca-certificates/ca-bundle/g' ./speedtest-cli/Makefile

	cd $PKG_PATH && echo "netspeedtest has been fixed!"
fi
