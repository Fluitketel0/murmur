#!/bin/bash
# Build Murmur.app, compiles with SwiftPM, assembles the .app bundle, and signs
# it. No Xcode required.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="${1:-debug}"            # debug | release
APP_NAME="Murmur"
BUNDLE_ID="com.murmur.app"
IDENTITY_NAME="Murmur Self-Signed"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> Compiling ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [ -f "$ROOT/Resources/MenuBarIcon.png" ]; then
    cp "$ROOT/Resources/MenuBarIcon.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"
fi

# Embed the Sparkle auto-update framework (from the resolved SwiftPM binary artifact)
# and add an rpath so @rpath/Sparkle.framework resolves inside the bundle.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -path "*/macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    mkdir -p "$APP_DIR/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
    echo "==> WARNING: Sparkle.framework not found; auto-update won't work. Run 'swift package resolve'."
fi

# Choose signing identity: stable self-signed if present, else ad-hoc.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    SIGN_ID="$IDENTITY_NAME"
    echo "==> Signing with '$SIGN_ID' (stable; TCC grants persist)."
else
    SIGN_ID="-"
    echo "==> Signing ad-hoc. Run ./scripts/make-cert.sh for persistent permissions."
fi

# Sign Sparkle's nested code first (deepest first), then the framework, then the app.
# (Inside-out signing instead of the deprecated --deep.)
FW_DST="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW_DST" ]; then
    for nested in \
        "Versions/B/Autoupdate" \
        "Versions/B/Updater.app" \
        "Versions/B/XPCServices/Downloader.xpc" \
        "Versions/B/XPCServices/Installer.xpc"; do
        [ -e "$FW_DST/$nested" ] && \
            codesign --force --options runtime --sign "$SIGN_ID" "$FW_DST/$nested"
    done
    codesign --force --options runtime --sign "$SIGN_ID" "$FW_DST"
fi

codesign --force \
    --options runtime \
    --entitlements "$ROOT/Resources/Murmur.entitlements" \
    --sign "$SIGN_ID" \
    "$APP_DIR"

echo "==> Built: $APP_DIR"

# Install into /Applications so Spotlight / Raycast index it (they don't look in a
# project folder), and register it with Launch Services so it shows up promptly.
# Best-effort: a failure here never fails the build.
INSTALL_PATH="/Applications/$APP_NAME.app"
if rm -rf "$INSTALL_PATH" 2>/dev/null && cp -R "$APP_DIR" "$INSTALL_PATH" 2>/dev/null; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALL_PATH" 2>/dev/null || true
    echo "==> Installed: $INSTALL_PATH (findable in Spotlight/Raycast)"
    echo "    Launch:  open \"$INSTALL_PATH\""
else
    echo "==> Could not install to /Applications (skipped); launch: open \"$APP_DIR\""
fi
