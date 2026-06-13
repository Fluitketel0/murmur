#!/bin/bash
# Cut a release: build, zip, EdDSA-sign for Sparkle, build a drag-to-Applications DMG,
# regenerate the appcast, commit it, and publish the GitHub release with both the zip
# and the DMG attached. Run after bumping the version in Resources/Info.plist. Requires
# the Sparkle signing key in the Keychain (make-keys once via Sparkle's generate_keys)
# and the gh CLI authenticated as the repo owner.
#
# Two artifacts on purpose: humans download the DMG (open it, drag Murmur to the
# Applications alias; the Finder drag strips the quarantine flag, so no App
# Translocation), while Sparkle keeps updating from the zip (no mounting, simplest and
# most reliable for the silent updater). The appcast points only at the zip.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Murmur"
REPO="Fluitketel0/murmur"
ZIP="$ROOT/dist/$APP_NAME.zip"
DMG="$ROOT/dist/$APP_NAME.dmg"
APPCAST="$ROOT/appcast.xml"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"
TAG="v$VERSION"
NOTES="${1:-Murmur $VERSION}"

# GitHub renders the notes as Markdown, but Sparkle renders the appcast description as
# HTML, where plain newlines collapse into one run-on line. So turn the same notes into
# HTML for the appcast: lines starting with "- " become a <ul> list, others become <p>.
# Write the notes as plain Markdown bullets; both surfaces format nicely, no extra effort.
NOTES_HTML="$(printf '%s\n' "$NOTES" | awk '
  BEGIN { inlist = 0 }
  /^[[:space:]]*-[[:space:]]+/ {
    if (!inlist) { print "<ul>"; inlist = 1 }
    sub(/^[[:space:]]*-[[:space:]]+/, "")
    print "<li>" $0 "</li>"
    next
  }
  { if (inlist) { print "</ul>"; inlist = 0 }
    if (length($0) > 0) print "<p>" $0 "</p>" }
  END { if (inlist) print "</ul>" }
')"

echo "==> Releasing $APP_NAME $VERSION (build $BUILD, tag $TAG)"

# 1. Build a release bundle and zip it (ditto preserves the code signature).
./scripts/build.sh release
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/dist/$APP_NAME.app" "$ZIP"

# 1b. Build the drag-to-Applications DMG (the human download). A staging folder holds
# the app beside an /Applications alias, so the mounted disk shows both side by side.
echo "==> Building $APP_NAME.dmg..."
DMG_STAGE="$(mktemp -d)"
cp -R "$ROOT/dist/$APP_NAME.app" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

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
      <description><![CDATA[$NOTES_HTML]]></description>
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

# 5. Publish the GitHub release with both the DMG (human download) and the zip
# (Sparkle) attached.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$ZIP" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$DMG" "$ZIP" --repo "$REPO" --title "$APP_NAME $VERSION" --notes "$NOTES"
fi

echo "==> Released $TAG. Appcast: https://raw.githubusercontent.com/$REPO/main/appcast.xml"
