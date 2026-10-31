#!/bin/bash
# 构建 QFSpeed.tipa（TrollStore 安装包）
#
# 为什么不用 Theos 的 application.mk：我们要的是 Payload/QFSpeed.app + .tipa 后缀，
# 不是 deb；直接 clang 编 + ldid 签，结构完全可控。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QFSpeed"
APP="build/Payload/${APP_NAME}.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
OUT="QFSpeed-${VERSION}.tipa"

rm -rf build "${OUT}"
mkdir -p "${APP}"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "==> SDK: ${SDK}"

echo "==> 编译（arm64 单架构）"
# 1.9.0 起只出 arm64，和 TrollSpeed 保持一致。
#
# 以前是 arm64 + arm64e 各编一份再 lipo 合并，结果合并出来的 fat 二进制里
# entitlements blob 是坏的（codesign 直接判 "invalid entitlements blob. The OS will
# ignore these entitlements"）—— 权限一失效，SpringBoard 就不肯合成我们注册的窗口，
# 现场表现正是「日志全正常、屏幕上什么都没有」。
# A12 及以后的设备跑 arm64 用户态二进制完全没问题，少一个架构换来签名可靠，很划算。
ARCH=arm64
OUT_BIN="build/${APP_NAME}.${ARCH}"
clang -arch "${ARCH}" \
      -isysroot "${SDK}" \
      -miphoneos-version-min=14.0 \
      -fobjc-arc -fblocks -O2 -Wno-deprecated-declarations \
      -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
      -framework AVFoundation -framework AVKit -framework CoreMedia -framework CoreVideo \
      -framework IOKit \
      -o "${OUT_BIN}" \
      main.m QFHostController.m QFSettingsPanel.m QFMetrics.m QFFloatingBar.m QFPiPBar.m QFHudPlugin.m

if command -v ldid >/dev/null 2>&1; then
    ldid -Sentitlements.plist "${OUT_BIN}"
    cp "${OUT_BIN}" "${APP}/${APP_NAME}"
else
    echo "    !! 没有 ldid，签名缺失，装上去权限会全部失效"
    cp "${OUT_BIN}" "${APP}/${APP_NAME}"
fi

echo "==> 校验签名里的 entitlements"
python3 - "${APP}/${APP_NAME}" <<'PY'
import sys, struct
path = sys.argv[1]
data = open(path, 'rb').read()
magic = struct.unpack('<I', data[:4])[0]
if magic in (0xcafebabe, 0xbebafeca):
    print("    !! fat 二进制，签名不可靠"); sys.exit(1)
ncmds = struct.unpack('<I', data[16:20])[0]
p, dataoff, datasize = 32, 0, 0
for _ in range(ncmds):
    cmd, size = struct.unpack('<II', data[p:p+8])
    if cmd == 0x1d:
        dataoff, datasize = struct.unpack('<II', data[p+8:p+16]); break
    p += size
if not datasize:
    print("    !! 没有 LC_CODE_SIGNATURE，签名没打上"); sys.exit(1)
b = data[dataoff:dataoff+datasize]
count = struct.unpack('>I', b[8:12])[0]
q, ents, has_der = 12, None, False
for _ in range(count):
    t, o = struct.unpack('>II', b[q:q+8]); q += 8
    m = struct.unpack('>I', b[o:o+4])[0]
    if m == 0xfade7171:
        ln = struct.unpack('>I', b[o+4:o+8])[0]
        ents = b[o+8:o+ln].decode('utf-8', 'replace')
    if m == 0xfade7172:
        has_der = True
need = ["com.apple.springboard.accessibility-window-hosting", "platform-application",
        "com.apple.private.security.no-sandbox", "com.apple.backboard.client"]
if not ents:
    print("    !! 没有 entitlements blob"); sys.exit(1)
missing = [k for k in need if k not in ents]
print("    entitlements: %d 字节, DER=%s" % (len(ents), "有" if has_der else "无"))
if missing:
    print("    !! 缺少关键权限: %s" % ", ".join(missing)); sys.exit(1)
print("    关键权限齐全")
PY

cp Info.plist "${APP}/Info.plist"

echo "==> 图标（用 sips 从 icon-src.jpg 缩放，无需 Pillow）"
if [ -f icon-src.jpg ] && command -v sips >/dev/null 2>&1; then
    # 先转成正方形大图，再出各尺寸
    sips -z 1024 1024 icon-src.jpg --out "${APP}/AppIcon.png" >/dev/null 2>&1
    sips -z 180 180   icon-src.jpg --out "${APP}/Icon-60@3x.png" >/dev/null 2>&1
    sips -z 120 120   icon-src.jpg --out "${APP}/Icon-60@2x.png" >/dev/null 2>&1
    echo "    图标已生成（剪影图）"
else
    echo "    跳过（缺 icon-src.jpg 或 sips，App 显示白图标）"
fi

echo "==> 打包 ${OUT}"
(cd build && zip -qry "../${OUT}" Payload)

echo "==> 完成"
lipo -archs "${APP}/${APP_NAME}" | sed 's/^/    架构: /'
ls -lh "${OUT}" | awk '{print "    产物: "$9" ("$5")"}'
