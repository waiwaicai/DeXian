#!/bin/bash
# 在模拟器上运行（无需签名，用于快速验证界面与规则引擎）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "请先安装 xcodegen：brew install xcodegen" >&2
  exit 1
fi
xcodegen generate

DEVICE="${1:-iPhone 16}"
echo "==> 在模拟器 [$DEVICE] 上运行"
xcodebuild -project DeXian.xcodeproj -scheme DeXian -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" build

echo "==> 运行单元测试（规则引擎）"
xcodebuild -project DeXian.xcodeproj -scheme DeXian -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" test
