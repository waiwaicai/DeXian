#!/bin/bash
# 把 xcodegen 生成的工程调整到当前 Xcode 能打开的格式。
#
# 设计要点（非常重要，这里的每条都对应一次真实的云编译失败）：
# 1) 不用 set -e / set -o pipefail。本脚本只是「锦上添花」的兼容处理，
#    任何一步失败都不应该把整个构建带崩。
# 2) 全程不使用管道。之前写成
#        xcodebuild -version | head -1 | awk ... | cut ...
#    head 读满一行就退出，xcodebuild（Objective-C 程序）写 stdout 时
#    拿到 SIGPIPE / abort，配合 pipefail 会让脚本以 134(SIGABRT) 退出，
#    而且是否触发取决于时序 —— 这正是之前云编译时好时坏、报
#    "Process completed with exit code 134" 的原因。
# 3) 不调用 xcodebuild 探测版本，改用 xcode-select -p 的安装路径解析，
#    完全不启动重型工具。
# 4) 探测不到版本时【不做任何降级】，保留 xcodegen 写出的格式。
#    现代 runner 上的 Xcode 都能直接打开 objectVersion 77。

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null)"; ROOT="$ROOT"
if [ -n "$ROOT" ]; then cd "$ROOT" || exit 0; fi

PBX="DeXian.xcodeproj/project.pbxproj"
if [ ! -f "$PBX" ]; then
  echo "==> 未找到 $PBX（请先执行 xcodegen generate），跳过格式处理"
  exit 0
fi

# ---- 探测 Xcode 主版本：只解析路径，不启动 xcodebuild ----
XCODE_MAJOR=""
DEVDIR=""
DEVDIR="$(xcode-select -p 2>/dev/null)"
if [ -z "$DEVDIR" ]; then DEVDIR="${DEVELOPER_DIR:-}"; fi

if [ -n "$DEVDIR" ]; then
  # 形如 /Applications/Xcode_26.3.app/Contents/Developer 或 .../Xcode.app/...
  APPNAME="${DEVDIR%%.app/*}"
  APPNAME="${APPNAME##*/}"
  VERPART="${APPNAME#Xcode_}"
  VERPART="${VERPART#Xcode}"
  XCODE_MAJOR="${VERPART%%.*}"
  case "$XCODE_MAJOR" in
    ''|*[!0-9]*) XCODE_MAJOR="" ;;
  esac
fi

if [ -z "$XCODE_MAJOR" ]; then
  echo "==> 未能确定 Xcode 版本，保留 xcodegen 生成的工程格式（不做降级）"
  echo "==> 工程格式处理完成"
  exit 0
fi

if [ "$XCODE_MAJOR" -ge 16 ]; then
  echo "==> 检测到 Xcode $XCODE_MAJOR，原生支持 objectVersion 77，无需降级"
  echo "==> 工程格式处理完成"
  exit 0
fi

SUPPORTED=60
COMPAT="Xcode 15.0"
if [ "$XCODE_MAJOR" -lt 15 ]; then
  SUPPORTED=56
  COMPAT="Xcode 14.0"
fi

# ---- 读取当前 objectVersion（sed 直接输出到变量，不经过管道）----
CURRENT="$(sed -n 's/^.*objectVersion = \([0-9][0-9]*\);.*$/\1/p' "$PBX" 2>/dev/null)"
CURRENT="${CURRENT:-0}"
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac

echo "==> 工程格式：objectVersion=$CURRENT（目标 $SUPPORTED）"

if [ "$CURRENT" -gt "$SUPPORTED" ]; then
  sed -E "s/^(.*)objectVersion = [0-9]+;/\1objectVersion = ${SUPPORTED};/" "$PBX" > "$PBX.tmp" 2>/dev/null
  if [ -s "$PBX.tmp" ]; then
    mv "$PBX.tmp" "$PBX" 2>/dev/null || rm -f "$PBX.tmp"
    echo "==> 已把 objectVersion 降到 $SUPPORTED"
  else
    rm -f "$PBX.tmp"
    echo "==> 降级失败，保留原格式（不影响较新的 Xcode）"
  fi
else
  echo "==> objectVersion 已兼容"
fi

if grep -q 'compatibilityVersion' "$PBX" 2>/dev/null; then
  sed -E "s/^(.*)compatibilityVersion = \"[^\"]*\";/\1compatibilityVersion = \"${COMPAT}\";/" "$PBX" > "$PBX.tmp" 2>/dev/null
  if [ -s "$PBX.tmp" ]; then
    mv "$PBX.tmp" "$PBX" 2>/dev/null || rm -f "$PBX.tmp"
  else
    rm -f "$PBX.tmp"
  fi
fi

echo "==> 工程格式处理完成"
exit 0
