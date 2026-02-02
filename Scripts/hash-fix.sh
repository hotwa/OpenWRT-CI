#!/bin/bash
# hash-fix.sh - 自动修复 OpenWRT 下载 hash mismatch
# 用法: ./Scripts/hash-fix.sh [工作目录]

set -e

WRT_DIR=${1:-./wrt}
cd "$WRT_DIR"

LOG_FILE=/tmp/download.log

echo "🔽 开始下载..."
if make download -j$(nproc) 2>&1 | tee "$LOG_FILE"; then
  echo "✅ 下载成功"
  exit 0
fi

# 检查是否是 hash mismatch
if ! grep -q "Hash mismatch for file" "$LOG_FILE"; then
  echo "❌ 下载失败，非 hash mismatch 问题"
  exit 1
fi

echo "🔧 检测到 hash mismatch，开始自动修复..."

# 解析并修复每个 mismatch
FIXED_COUNT=0
while IFS= read -r line; do
  FILE=$(echo "$line" | sed -n 's/.*file \(.*\): expected.*/\1/p')
  GOT=$(echo "$line" | sed -n 's/.*got \([a-f0-9]*\).*/\1/p')
  
  if [ -n "$FILE" ] && [ -n "$GOT" ]; then
    echo "  📦 $FILE"
    echo "     $GOT"
    
    # 查找并更新 PKG_HASH
    PKG_MAKEFILE=$(find . -name "Makefile" -type f -exec grep -l "$FILE" {} \; 2>/dev/null | head -1)
    if [ -n "$PKG_MAKEFILE" ]; then
      sed -i "s/PKG_HASH:=.*/PKG_HASH:=$GOT/" "$PKG_MAKEFILE"
      echo "     ✅ 已更新 $(basename "$PKG_MAKEFILE")"
      FIXED_COUNT=$((FIXED_COUNT + 1))
    else
      echo "     ❌ 未找到 Makefile"
    fi
  fi
done < <(grep "Hash mismatch for file" "$LOG_FILE")

if [ $FIXED_COUNT -eq 0 ]; then
  echo "⚠️  未找到可修复的 hash"
  exit 1
fi

echo ""
echo "🔄 重新下载 ($FIXED_COUNT 个包已修复)..."
make download -j$(nproc)

echo ""
echo "✅ 完成！已修复 $FIXED_COUNT 个 hash mismatch"
