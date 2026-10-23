#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
swift build --build-system native -c release --arch arm64
ARM_PRODUCT_DIR="$(swift build --build-system native -c release --arch arm64 --show-bin-path)"
swift build --build-system native -c release --arch x86_64
INTEL_PRODUCT_DIR="$(swift build --build-system native -c release --arch x86_64 --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/HS Shot.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/.build/HSShot.iconset"
lipo -create "$ARM_PRODUCT_DIR/HSShot" "$INTEL_PRODUCT_DIR/HSShot" -output "$APP_DIR/Contents/MacOS/HSShot"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/.build/icon-1024.png"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$PROJECT_DIR/.build/icon-1024.png" --out "$PROJECT_DIR/.build/HSShot.iconset/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    DOUBLE_SIZE=$((ICON_SIZE * 2))
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$PROJECT_DIR/.build/icon-1024.png" --out "$PROJECT_DIR/.build/HSShot.iconset/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$PROJECT_DIR/.build/HSShot.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier jp.huntersite.hsshot "$APP_DIR"
codesign --verify --strict "$APP_DIR"
print "Built: $APP_DIR"
