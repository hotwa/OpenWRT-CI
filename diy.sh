#!/bin/bash

#WRT_REPO='https://github.com/LiBwrt/openwrt-6.x'
#WRT_BRANCH='k6.12-nss'

#WRT_REPO='https://github.com/davidtall/immortalwrt-6.12'
#WRT_BRANCH='main'

WRT_REPO='https://github.com/VIKINGYFY/immortalwrt'
WRT_BRANCH='main'

if [ -n "$1" ]; then
    # 如果有传递参数，赋值给WRT_TARGET
    filename=$(basename "$1")
    export WRT_CONFIG="${filename%.*}"
else
    # 如果没有传递参数，设置默认值
    export WRT_CONFIG="IPQ60XX-NOWIFI"
fi

if [ -n "$2" ]; then
    WRT_REPO="$2"
fi

export WRT_DIR=wrt
export GITHUB_WORKSPACE=$(pwd)
export WRT_DATE=$(TZ=UTC-8 date +"%y.%m.%d_%H.%M.%S")
export WRT_VER=$(echo $WRT_REPO | cut -d '/' -f 5-)-$WRT_BRANCH
export WRT_TYPE=$(sed -n "1{s/^#//;s/\r$//;p;q}" $GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt)
export WRT_NAME='OWRT'
export WRT_SSID='OWRT'
export WRT_WORD='12345678'
export WRT_THEME='argon'
export WRT_IP='192.168.10.1'
export WRT_CI='WSL-OpenWRT-CI'
export WRT_ARCH=$(sed -n 's/.*_DEVICE_\(.*\)_DEVICE_.*/\1/p' $GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt | head -n 1)
export CI_NAME='QCA-6.12-LiBwrt'
export WRT_TARGET=$(grep -m 1 -oP '^CONFIG_TARGET_\K[\w]+(?=\=y)' $GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt | tr '[:lower:]' '[:upper:]')

. $GITHUB_WORKSPACE/Scripts/function.sh

if [ ! -d $WRT_DIR ]; then
  git clone --depth=1 --single-branch --branch $WRT_BRANCH $WRT_REPO $WRT_DIR
  cd $WRT_DIR
else
  cd $WRT_DIR
  git remote set-url origin $WRT_REPO
  rm -rf feeds/*
  git clean -f
  git reset --hard
  git pull
fi

# 升级 Go 版本到 1.25.6（解决 tailscale 编译问题）
GOLANG_MK=$(find $WRT_DIR/include/lang -name "golang*.mk" 2>/dev/null | head -1)
if [ -n "$GOLANG_MK" ] && [ -f "$GOLANG_MK" ]; then
  echo "升级 Go 版本到 1.25.6..."
  # 查找并替换 GO_VERSION
  sed -i 's/GO_VERSION := 1\.[0-9]*\.[0-9]*/GO_VERSION := 1.25.6/' "$GOLANG_MK" 2>/dev/null || true
  # 查找并替换 GOLANG_MIRROR_VERSION
  sed -i 's/GOLANG_MIRROR_VERSION := 1\.[0-9]*\.[0-9]*/GOLANG_MIRROR_VERSION := 1.25.6/' "$GOLANG_MK" 2>/dev/null || true
  cat "$GOLANG_MK" | grep -E "GO_VERSION|GOLANG_MIRROR_VERSION" || true
fi

#rm -rf feeds
./scripts/feeds update -a && ./scripts/feeds install -a

# 注意：Passwall 使用 xiaorouji 版本（在 Scripts/Packages.sh 中配置）

cd package/
$GITHUB_WORKSPACE/Scripts/Packages.sh
$GITHUB_WORKSPACE/Scripts/Handles.sh
cd ..

generate_config

$GITHUB_WORKSPACE/Scripts/Settings.sh

make defconfig
# make download -j8
# make -j$(nproc) || make V=s -j1

# make download -j8 && (make -j$(nproc) || make V=s -j1)