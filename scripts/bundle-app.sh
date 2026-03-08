#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClaudeUsageBar"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

BINARY="$PROJECT_DIR/.build/release/$APP_NAME"

echo "==> Creating .app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "==> Copying binary..."
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Copying Info.plist..."
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Copying app icon..."
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Code signing..."
# Use Apple Development identity for stable Keychain ACL (no repeated password prompts).
# Falls back to ad-hoc if no identity is available.
IDENTITY=$(security find-identity -v -p codesigning | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "0 valid identities found" ]; then
    echo "    Using identity: $IDENTITY"
    codesign --sign "$IDENTITY" --force --deep "$APP_BUNDLE"
else
    echo "    No signing identity found, using ad-hoc"
    codesign --sign - --force --deep "$APP_BUNDLE"
fi

echo ""
echo "✅ Done! To launch:"
echo "   open \"$APP_BUNDLE\""
echo ""
echo "   Or move to Applications:"
echo "   cp -R \"$APP_BUNDLE\" /Applications/"
