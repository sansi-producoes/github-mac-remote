#!/bin/bash
# setup-blackbird.sh - Preinstall the BlackBird anti-detect browser on the Mac
# session so the operator only needs to log in. Downloads the official DMG
# from the vendor CDN, mounts it, copies the .app to /Applications, strips
# the quarantine flag and prints the installed version.
set -e

DMG=/tmp/blackbird-latest.dmg
MOUNT=/Volumes/BlackBirdInstall
APP_SRC="$MOUNT/BlackBird.app"
APP_DST="/Applications/BlackBird.app"

echo "🔐 Installing BlackBird browser (official CDN)..."
rm -f "$DMG"
curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "$DMG" https://cdn.blckbrd.cc/mac/latest.dmg

# Detach any stale mount from a previous attempt, then mount fresh
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
hdiutil attach -quiet -nobrowse -readonly "$DMG" -mountpoint "$MOUNT"

rm -rf "$APP_DST"
cp -R "$APP_SRC" /Applications/
hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true
rm -f "$DMG"

# Remove the Gatekeeper quarantine flag so first launch is smooth
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DST/Contents/Info.plist" 2>/dev/null || echo "unknown")
echo "🔐 BlackBird installed: version $VERSION"
