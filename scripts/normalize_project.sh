#!/bin/bash
# 把 xcodegen 生成的工程降到当前 Xcode 能打开的格式。
# 新版 xcodegen 默认写 objectVersion = 77（Xcode 16 格式），
# 老一些的 Xcode（15.x）会直接报 "future Xcode project file format" 而拒绝打开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PBX="DeXian.xcodeproj/project.pbxproj"
if [ ! -f "$PBX" ]; then
  echo "错误：未找到 $PBX（请先运行 xcodegen generate）。" >&2
  exit 1
fi

# 取当前 Xcode 支持的最大 objectVersion
SUPPORTED="56"
if command -v xcodebuild >/dev/null 2>&1; then
  XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)"
  case "$XCODE_MAJOR" in
    ''|*[!0-9]*) XCODE_MAJOR=15 ;;
  esac
  if [ "$XCODE_MAJOR" -ge 16 ]; then
    SUPPORTED="77"
  elif [ "$XCODE_MAJOR" -ge 15 ]; then
    SUPPORTED="60"
  else
    SUPPORTED="56"
  fi
fi

CURRENT="$(grep -m1 'objectVersion' "$PBX" | tr -dc '0-9' || true)"
echo "==> 工程格式：objectVersion=$CURRENT，当前 Xcode 支持 $SUPPORTED"

if [ -n "$CURRENT" ] && [ "$CURRENT" -gt "$SUPPORTED" ]; then
  # objectVersion 只出现在开头那一行
  awk -v v="$SUPPORTED" 'NR==1{print; next} /objectVersion[[:space:]]*=/ && !done {sub(/objectVersion[[:space:]]*=[[:space:]]*[0-9]+/, "objectVersion = " v); done=1} {print}' \
    "$PBX" > "$PBX.tmp"
  mv "$PBX.tmp" "$PBX"
  echo "==> 已降级为 objectVersion=$SUPPORTED"
else
  echo "==> 无需调整"
fi

grep -m1 'objectVersion' "$PBX"
