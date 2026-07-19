#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PDFlab"
BUNDLE_ID="com.pdflab.app"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY_DST="$MACOS_DIR/$APP_NAME"
VERSION="$(bash "$ROOT/scripts/app_version.sh")"
ICON_SRC="$ROOT/Resources/AppIcon.icns"
UNIVERSAL_BUILD_DIR="$ROOT/.build/universal-release"
ARM64_TRIPLE="arm64-apple-macosx14.0"
X86_64_TRIPLE="x86_64-apple-macosx14.0"
ARM64_BUILD_DIR="$UNIVERSAL_BUILD_DIR/arm64"
X86_64_BUILD_DIR="$UNIVERSAL_BUILD_DIR/x86_64"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

cd "$ROOT"
ARM64_BIN_DIR="$(swift build -c release --triple "$ARM64_TRIPLE" --scratch-path "$ARM64_BUILD_DIR" --show-bin-path)"
X86_64_BIN_DIR="$(swift build -c release --triple "$X86_64_TRIPLE" --scratch-path "$X86_64_BUILD_DIR" --show-bin-path)"
ARM64_BINARY="$ARM64_BIN_DIR/PDFLabApp"
X86_64_BINARY="$X86_64_BIN_DIR/PDFLabApp"

swift build -c release --triple "$ARM64_TRIPLE" --scratch-path "$ARM64_BUILD_DIR"
swift build -c release --triple "$X86_64_TRIPLE" --scratch-path "$X86_64_BUILD_DIR"

for binary in "$ARM64_BINARY" "$X86_64_BINARY"; do
    [[ -f "$binary" ]] || { echo "Missing architecture slice: $binary" >&2; exit 1; }
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$BINARY_DST"
ARCHITECTURES="$(lipo -archs "$BINARY_DST")"
[[ " $ARCHITECTURES " == *" arm64 "* ]] || { echo "Universal binary is missing arm64" >&2; exit 1; }
[[ " $ARCHITECTURES " == *" x86_64 "* ]] || { echo "Universal binary is missing x86_64" >&2; exit 1; }
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 PDFlab contributors. All rights reserved.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP_DIR"
codesign --verify --deep --strict --all-architectures "$APP_DIR"

echo "Built $APP_DIR ($ARCHITECTURES)"
