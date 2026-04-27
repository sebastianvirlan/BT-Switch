#!/bin/bash
#
# build.sh — compile BTSwitch.app without needing an Xcode project.
#
# This builds and codesigns BTSwitch.app into ./build/BTSwitch.app.
# Drag that app into /Applications.
#
# Requires Xcode Command Line Tools (xcode-select --install).

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BTSwitch"
BUNDLE_ID="com.user.btswitch"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SOURCES_DIR="BTSwitch"

# Clean.
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "==> Compiling Swift sources…"
SWIFT_FILES=$(find "$SOURCES_DIR" -name "*.swift" | tr '\n' ' ')

# Build for the current architecture. If you want a universal binary,
# compile twice (arm64 and x86_64) and use `lipo` to combine.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    arm64)  TARGET="arm64-apple-macos13.0" ;;
    x86_64) TARGET="x86_64-apple-macos13.0" ;;
    *) echo "Unsupported architecture: $HOST_ARCH"; exit 1 ;;
esac
echo "    target: $TARGET"

# shellcheck disable=SC2086
xcrun swiftc \
    -target "$TARGET" \
    -framework IOBluetooth \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Network \
    -O \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    $SWIFT_FILES

echo "==> Copying Info.plist and entitlements…"
cp "$SOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Substitute the build placeholders ($(EXECUTABLE_NAME) etc.) with real values.
sed -i '' "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" "$APP_BUNDLE/Contents/Info.plist"
sed -i '' "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" "$APP_BUNDLE/Contents/Info.plist"
sed -i '' "s/\$(PRODUCT_NAME)/$APP_NAME/g" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ad-hoc code signing with entitlements…"
codesign --force --sign - \
    --entitlements "$SOURCES_DIR/$APP_NAME.entitlements" \
    "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"
echo
echo "Next steps:"
echo "  1. mv $APP_BUNDLE /Applications/"
echo "  2. Open it (right-click → Open the first time, to bypass Gatekeeper)"
echo "  3. Grant Bluetooth permission when prompted"
echo "  4. Right-click the menu bar icon → Settings… to configure"
