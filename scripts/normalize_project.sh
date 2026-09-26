#!/bin/bash
# 把 xcodegen 生成的工程降到当前 Xcode 能打开的格式。
# 新版 xcodegen 默认写 objectVersion = 77（Xcode 16 格式），
# 较早的 Xcode（15.x）会直接报 future Xcode project file format 而拒绝打开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PBX="DeXian.xcodeproj/project.pbxproj"
if [ ! -f "$PBX" ]; then
  printf 'error: %s not found (run xcodegen generate first)\n' "$PBX" >&2
  exit 1
fi

SUPPORTED=56
COMPAT="Xcode 14.0"
if command -v xcodebuild >/dev/null 2>&1; then
  XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)"
  case "$XCODE_MAJOR" in
    ''|*[!0-9]*) XCODE_MAJOR=15 ;;
  esac
  if [ "$XCODE_MAJOR" -ge 16 ]; then
    SUPPORTED=77
    COMPAT="Xcode 16.0"
  elif [ "$XCODE_MAJOR" -ge 15 ]; then
    SUPPORTED=60
    COMPAT="Xcode 15.0"
  fi
fi

CURRENT="$(sed -n 's/^.*objectVersion = \([0-9][0-9]*\);.*$/\1/p' "$PBX" | head -1)"
CURRENT="${CURRENT:-0}"

printf '==> project format: objectVersion=%s (target %s)\n' "$CURRENT" "$SUPPORTED"

if [ "$CURRENT" -gt "$SUPPORTED" ]; then
  sed -E "s/^(.*)objectVersion = [0-9]+;/\1objectVersion = ${SUPPORTED};/" "$PBX" > "$PBX.tmp" && mv "$PBX.tmp" "$PBX"
  printf '==> downgraded objectVersion to %s\n' "$SUPPORTED"
else
  printf '==> objectVersion already compatible\n'
fi

if grep -q 'compatibilityVersion' "$PBX"; then
  sed -E "s/^(.*)compatibilityVersion = \"[^\"]*\";/\1compatibilityVersion = \"${COMPAT}\";/" "$PBX" > "$PBX.tmp" && mv "$PBX.tmp" "$PBX"
fi

NOW="$(sed -n 's/^.*objectVersion = \([0-9][0-9]*\);.*$/\1/p' "$PBX" | head -1)"
printf '==> final objectVersion=%s\n' "${NOW:-unknown}"
