#!/bin/zsh
# Makes the download for GitHub Releases: build/Audio-Capture.zip, plus its SHA-256. The name never
# changes, so releases/latest/download/Audio-Capture.zip always points at the newest version.
# Builds the app without installing it. Upload the zip to a release; nothing is published from here.
set -euo pipefail
cd "$(dirname "$0")"
# Zip entries carry local times next to UTC ones; in UTC both match, so the zip doesn't reveal a time zone.
export TZ=UTC
# Ad hoc, whatever certificates this Mac has: a downloaded app should carry no one's name or team.
BUILD_ONLY=1 FORCE_ADHOC=1 ./build.sh
APP="build/Audio Capture.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Audio-Capture.zip"
rm -f "$ZIP"
# A clean copy with no extended attributes (Finder tags, download history), zipped without
# resource forks, so the archive holds exactly the signed bundle and nothing about this Mac.
CLEAN=$(mktemp -d)
ditto --norsrc --noextattr --noqtn "$APP" "$CLEAN/Audio Capture.app"
xattr -cr "$CLEAN/Audio Capture.app"
ditto -c -k --norsrc --noextattr --keepParent "$CLEAN/Audio Capture.app" "$ZIP"
rm -rf "$CLEAN"
# Check what people will get: unzip a copy and verify its signature.
CHECK=$(mktemp -d)
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Audio Capture.app"
rm -rf "$CHECK"
echo "Made $ZIP for version $VERSION ($(du -h "$ZIP" | cut -f1)), signature verified after unzipping"
shasum -a 256 "$ZIP"
