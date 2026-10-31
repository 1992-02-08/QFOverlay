#!/bin/bash
# 构建 QFOverlay 演示 .tipa（TrollStore 安装包）
#
# 关键点（来自 2.1.6 的踩坑）：
#   1) 只编 arm64 单架构。fat（arm64+arm64e）会让 entitlements blob 损坏，
#      SpringBoard 不合成窗口 —— 表现是「日志正常、屏幕啥都没有」。
#   2) 必须用 ldid 签 entitlements，否则权限全失效。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QFOverlayDemo"
APP="build/Payload/${APP_NAME}.app"
OUT="QFOverlay-${APP_NAME}.tipa"

rm -rf build "${OUT}"
mkdir -p "${APP}"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "==> SDK: ${SDK}"

echo "==> 编译（arm64 单架构）"
clang -arch arm64 \
      -isysroot "${SDK}" \
      -miphoneos-version-min=14.0 \
      -fobjc-arc -fblocks -O2 -Wno-deprecated-declarations \
      -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
      -o "build/${APP_NAME}.arm64" \
      HostApp/main.m HostApp/AppDelegate.m QFOverlay/QFOverlayHUD.m

echo "==> ldid 签名"
ldid -SQFOverlay/entitlements.plist "build/${APP_NAME}.arm64"

cp "build/${APP_NAME}.arm64" "${APP}/${APP_NAME}"
cp HostApp/Info.plist "${APP}/Info.plist"

echo "==> 打包 ${OUT}"
(cd build && zip -qry "../${OUT}" Payload)

echo "==> 完成：$(ls -lh "${OUT}" | awk '{print $9" ("$5")"}')"
