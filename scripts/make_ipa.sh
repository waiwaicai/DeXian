#!/bin/bash
# 得闲（DeXian）一键构建 IPA
#
# 用法：
#   ./scripts/make_ipa.sh                      # 未签名 IPA（需自签后安装）
#   TEAM_ID=XXXXXXXXXX ./scripts/make_ipa.sh   # 使用指定开发者账号签名
#
# 说明：不使用 pipefail / 管道，避免 head 之类提前退出导致上游 SIGPIPE，
# 在 macOS 上会把退出码变成 134(SIGABRT)/141(SIGPIPE)，表现为莫名其妙的失败。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="DeXian"
PROJECT="DeXian.xcodeproj"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/DeXian.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OUTPUT_DIR="$ROOT/outputs"
IPA_NAME="DeXian.ipa"

echo "==> 检查环境"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未找到 xcodebuild，请在 macOS 上运行本脚本。" >&2
  exit 1
fi

echo "==> 生成 Xcode 工程"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 xcodegen，尝试通过 Homebrew 安装..."
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "错误：请先安装 xcodegen（brew install xcodegen）后重试。" >&2
    exit 1
  fi
fi
xcodegen generate

# 兼容较老的 Xcode：新版 xcodegen 会写 Xcode 16 的工程格式
if [ -f "$ROOT/scripts/normalize_project.sh" ]; then
  chmod +x "$ROOT/scripts/normalize_project.sh" 2>/dev/null || true
  "$ROOT/scripts/normalize_project.sh" || echo "warning: normalize_project.sh 返回非零，已忽略"
fi

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" 2>/dev/null || true
rm -f "$EXPORT_DIR"/*.ipa 2>/dev/null || true

echo "==> 归档（Release）"
if [ -n "${TEAM_ID:-}" ]; then
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates
else
  echo "（未提供 TEAM_ID，将生成未签名归档）"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
fi

echo "==> 打包 IPA"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "错误：未找到 .app（$APP_PATH）" >&2
  echo "归档目录内容：" >&2
  ls -la "$ARCHIVE_PATH/Products/Applications" 2>/dev/null >&2 || true
  exit 1
fi

WORK="$BUILD_DIR/ipa"
rm -rf "$WORK"
mkdir -p "$WORK/Payload"
cp -R "$APP_PATH" "$WORK/Payload/"
# 移除旧的签名残留，便于自签工具处理
rm -rf "$WORK/Payload/$SCHEME.app/_CodeSignature" 2>/dev/null || true

# sideLoad 版本核对：xcodegen 在归档时没有展开 MARKETING_VERSION，
# 这里直接写入实际短版本，避免侧载工具把它当成旧包。
PLIST="$WORK/Payload/$SCHEME.app/Info.plist"
if [ -f "$PLIST" ]; then
  SHORT_VERSION="1.0.23"
  plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$PLIST"
fi

( cd "$WORK" && zip -qry "$OUTPUT_DIR/$IPA_NAME" Payload )

IPA_BYTES="$(wc -c < "$OUTPUT_DIR/$IPA_NAME" 2>/dev/null || echo 0)"
IPA_BYTES="${IPA_BYTES:-0}"

echo ""
echo "完成：$OUTPUT_DIR/$IPA_NAME"
echo "   大小：$IPA_BYTES 字节"
echo ""
echo "安装方式（任选）："
echo "  1. 有开发者账号：TEAM_ID=你的团队ID ./scripts/make_ipa.sh 会产出可直接安装的 IPA"
echo "  2. 自签：用 AltStore / SideStore / Sideloadly / TrollStore 安装上面的 IPA"
