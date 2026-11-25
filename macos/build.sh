#!/bin/bash
# 构建 DisplayRotate.app（macOS 14+）
#   ./build.sh              构建 arm64（Apple Silicon）
#   ./build.sh --universal  构建 arm64 + x86_64 通用二进制
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DisplayRotate"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SOURCES=("$ROOT"/Sources/*.swift)

FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
    local target="$1" output="$2"
    swiftc -O -swift-version 5 \
        -target "$target" \
        -module-cache-path "$BUILD_DIR/.module-cache" \
        "${FRAMEWORKS[@]}" \
        -o "$output" \
        "${SOURCES[@]}"
}

if [[ "${1:-}" == "--universal" ]]; then
    echo "==> 编译 arm64"
    compile "arm64-apple-macos14.0" "$BUILD_DIR/bin-arm64"
    echo "==> 编译 x86_64"
    compile "x86_64-apple-macos14.0" "$BUILD_DIR/bin-x86_64"
    echo "==> 合并通用二进制"
    lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$BUILD_DIR/bin-arm64" "$BUILD_DIR/bin-x86_64"
    rm -f "$BUILD_DIR/bin-arm64" "$BUILD_DIR/bin-x86_64"
else
    echo "==> 编译 arm64"
    compile "arm64-apple-macos14.0" "$APP/Contents/MacOS/$APP_NAME"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "    已签名" || echo "    签名失败（可忽略，本机仍可运行）"

echo "==> 完成：$APP"
echo "    运行：open \"$APP\""
echo "    自检：\"$APP/Contents/MacOS/$APP_NAME\" --selftest"
