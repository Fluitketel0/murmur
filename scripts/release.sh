#!/bin/bash
# Cut a release: build, zip, EdDSA-sign for Sparkle, regenerate the appcast, commit it,
# and publish the GitHub release with the zip attached. Run after bumping the version in
# Resources/Info.plist. Requires the Sparkle signing key in the Keychain (make-keys once
# via Sparkle's generate_keys) and the gh CLI authenticated as the repo owner.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Murmur"
REPO="Fluitketel0/murmur"
ZIP="$ROOT/dist/$APP_NAME.zip"
APPCAST="$ROOT/appcast.xml"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"
TAG="v$VERSION"
NOTES="${1:-Murmur $VERSION}"

echo "==> Releasing $APP_NAME $VERSION (build $BUILD, tag $TAG)"

# 1. Build a release bundle and zip it (ditto preserves the code signature).
./scripts/build.sh release
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/dist/$APP_NAME.app" "$ZIP"

# 2. EdDSA-sign the zip with the key in the Keychain.
SIGN_UPDATE="$(find "$ROOT/.build/artifacts" -path "*/bin/sign_update" 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found (run 'swift package resolve')"; exit 1; }
SIG_LINE="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "Failed to sign update: $SIG_LINE"; exit 1; }

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$APP_NAME.zip"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

# 3. Regenerate the appcast advertising this version (always points at the latest).
cat > "$APPCAST" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Murmur</title>
    <description>Updates for Murmur, private on-device speech-to-text for macOS.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <description><![CDATA[$NOTES]]></description>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_URL" sparkle:edSignature="$ED_SIG" length="$LENGTH" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
echo "==> Wrote $APPCAST"

# 4. Commit the appcast so SUFeedURL (raw.githubusercontent .../appcast.xml) serves it.
git add appcast.xml Resources/Info.plist
git commit -q -m "release: $APP_NAME $VERSION" || echo "    (nothing to commit)"
git push

# 5. Publish the GitHub release with the zip attached.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$APP_NAME $VERSION" --notes "$NOTES"
fi

echo "==> Released $TAG. Appcast: https://raw.githubusercontent.com/$REPO/main/appcast.xml"
