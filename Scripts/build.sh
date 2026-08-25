#!/bin/bash
# ============================================================================
# 爱弥斯桌宠 构建脚本
# 产物: build/AemeathPet.app
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="AemeathPet"
BUNDLE="build/${APP_NAME}.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> 清理旧构建"
rm -rf build
mkdir -p "$MACOS" "$RES/icon"

echo "==> 检查资源（缺失时自动提取）"
if [ ! -f Resources/manifest.json ]; then
    python3 Scripts/extract_frames.py
fi

echo "==> 编译 (swiftc -Osize, 双架构通用)"
mkdir -p build/module-cache build/arch
# Apple Silicon (arm64) 与 Intel (x86_64) 分别编译，再合并为通用二进制
for ARCH in arm64 x86_64; do
    swiftc -Osize -target "$ARCH-apple-macosx12.0" \
        -Xcc -fmodules-cache-path="$ROOT/build/module-cache" \
        -framework AppKit -framework QuartzCore -framework CoreVideo \
        -o "build/arch/$APP_NAME-$ARCH" \
        Sources/*.swift || exit 1
done
lipo -create build/arch/$APP_NAME-arm64 build/arch/$APP_NAME-x86_64 -output "$MACOS/$APP_NAME"
lipo -info "$MACOS/$APP_NAME"

echo "==> 拷贝资源"
cp -R Resources/frames "$RES/"
cp Resources/manifest.json "$RES/"
cp Resources/icon/*.png "$RES/icon/"

echo "==> 生成 App 图标 (icns)"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="Resources/icon/app_icon_1024.png"
sips -z 16 16  "$SRC" --out "$ICONSET/icon_16x16.png"   >/dev/null
sips -z 32 32  "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32  "$SRC" --out "$ICONSET/icon_32x32.png"   >/dev/null
sips -z 64 64  "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AemeathPet</string>
    <key>CFBundleDisplayName</key>
    <string>爱弥斯桌宠</string>
    <key>CFBundleIdentifier</key>
    <string>com.aemeath.pet</string>
    <key>CFBundleExecutable</key>
    <string>AemeathPet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> 代码签名 (ad-hoc)"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "==> 打包发行版 zip（通用架构：Apple Silicon + Intel）"
rm -f "build/${APP_NAME}-macOS.zip"
ditto -c -k --keepParent "$BUNDLE" "build/${APP_NAME}-macOS.zip"
echo "   发行包: build/${APP_NAME}-macOS.zip"

echo ""
echo "✅ 构建完成: $BUNDLE"
echo "   运行: open $BUNDLE"
echo "   自检: $MACOS/$APP_NAME --selftest"
echo "   发行包: build/${APP_NAME}-macOS.zip"
