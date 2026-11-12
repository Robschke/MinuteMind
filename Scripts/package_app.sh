#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname "$0")/.." && pwd)"
BUILD_BIN_PATH="$(swift build -c release --show-bin-path)"
APP_NAME="MinuteMind"
DEST_ARG="${1:-}"
APP_BUNDLE="$PROJECT_ROOT/dist/${APP_NAME}.app"
INSTALL_DEST=""

if [[ "$DEST_ARG" == "--install" ]]; then
  INSTALL_DEST="$HOME/Applications/${APP_NAME}.app"
fi

echo "Running tests..."
SKIP_NETWORK_TESTS=1 swift test

echo "Building release binary..."
swift build -c release

echo "Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$PROJECT_ROOT/Sources/App/Supporting/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$PROJECT_ROOT/Sources/App/Supporting/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Licenses ship with the binary (MIT for MinuteMind, the dependencies' own terms for them)
cp "$PROJECT_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"

ENTITLEMENTS="$PROJECT_ROOT/Sources/App/Supporting/Entitlements.plist"
SIGNING_IDENTITY="-"

# Check for a known self-signed certificate in the keychain
if security find-identity -v -p codesigning | grep -q "MinuteMind-Self-Signed"; then
    echo "Found 'MinuteMind-Self-Signed' certificate. Using it for signing."
    SIGNING_IDENTITY="MinuteMind-Self-Signed"
else
    echo "No 'MinuteMind-Self-Signed' certificate found. Using ad-hoc signing."
    echo "NOTE: Ad-hoc signing may cause repeated permission prompts on rebuild."
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

if [[ -n "$INSTALL_DEST" ]]; then
  echo "Copying app bundle into $INSTALL_DEST"
  mkdir -p "$(dirname "$INSTALL_DEST")"
  rm -rf "$INSTALL_DEST"
  cp -R "$APP_BUNDLE" "$INSTALL_DEST"
  echo "Installed. Launch it via Finder or: open \"$INSTALL_DEST\""
else
  echo "Done. Open the app with: open \"$APP_BUNDLE\""
  echo "Pass --install to copy it into ~/Applications automatically."
fi
