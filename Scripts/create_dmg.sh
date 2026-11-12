#!/bin/zsh
set -euo pipefail

# Configuration
APP_NAME="MinuteMind"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
DMG_DIR="$DIST_DIR/dmg-contents"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$PROJECT_DIR/Sources/App/Supporting/Entitlements.plist"
BUILD_BIN_PATH="$(swift build -c release --show-bin-path)"

cd "$PROJECT_DIR"

echo "Running tests..."
SKIP_NETWORK_TESTS=1 swift test

echo "Building release binary..."
swift build -c release

echo "Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the release binary
cp "$BUILD_BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "Sources/App/Supporting/Info.plist" "$APP_BUNDLE/Contents/"

# Copy app icon
cp "Sources/App/Supporting/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Licenses ship with the binary
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_BUNDLE/Contents/Resources/"

# Code sign with entitlements
SIGNING_IDENTITY="-"
if security find-identity -v -p codesigning | grep -q "MinuteMind-Self-Signed"; then
    echo "Found 'MinuteMind-Self-Signed' certificate. Using it for signing."
    SIGNING_IDENTITY="MinuteMind-Self-Signed"
else
    echo "No 'MinuteMind-Self-Signed' certificate found. Using ad-hoc signing."
fi

if command -v codesign >/dev/null 2>&1; then
    echo "Code signing app bundle..."
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "Preparing DMG contents..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# Copy app bundle to DMG staging directory
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create a symbolic link to Applications folder for easy drag-and-drop install
ln -s /Applications "$DMG_DIR/Applications"

echo "Creating DMG..."
rm -f "$DMG_PATH"

# Create DMG with hdiutil
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up staging directory
rm -rf "$DMG_DIR"

echo ""
echo "✅ DMG created successfully: $DMG_PATH"
echo ""
echo "The DMG contains only the application bundle."
echo "User data (credentials, recordings, transcripts) is stored in:"
echo "  ~/Library/Application Support/MinuteMind/"
echo "and is NOT included in this DMG."
