#!/bin/zsh
# Builds Audio Capture.app into ./build. Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Audio\ Capture.app
rm -rf "$APP" build/AppIcon.iconset build/AppIcon.icon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AudioCapture "$APP/Contents/MacOS/AudioCapture"
# Debug-map entries name the folders the build ran in (the builder's home folder): stripped before signing.
strip -S "$APP/Contents/MacOS/AudioCapture"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Translations: each string catalog compiles into one folder per language (menus, window, permission prompts).
for catalog in Support/Localizable.xcstrings Support/InfoPlist.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources" >/dev/null
done
# The icon: light and dark artwork in an Icon Composer file, so macOS shows the one the icon style asks for.
cp -R Support/AppIcon.icon build/AppIcon.icon
.build/release/IconTool build/AppIcon.iconset --artwork build/AppIcon.icon/Assets >/dev/null
xcrun actool "$PWD/build/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.4 \
  --app-icon AppIcon --output-partial-info-plist "$PWD/build/AppIcon.plist" >/dev/null
# A stable identity keeps the System Audio Recording permission across rebuilds; ad-hoc resets it.
IDENTITY=$([[ -n "${FORCE_ADHOC:-}" ]] || security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier io.github.lexreman.audiocapture "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --sign - --identifier io.github.lexreman.audiocapture "$APP"
  if [[ -n "${FORCE_ADHOC:-}" ]]; then echo "Signed ad-hoc, as every download is"
  else echo "Signed ad-hoc (no Apple Development certificate found): macOS may ask for audio permission again after a rebuild"; fi
fi
echo "Built $APP"
[[ -n "${BUILD_ONLY:-}" ]] && exit 0     # release.sh: build the bundle, never touch /Applications

# Install: /Applications always holds the latest build. A running copy is quit, replaced and reopened,
# unless it is recording or paused (the "inProgress" key is set exactly then): that copy is never touched.
INSTALL="/Applications/Audio Capture.app"
BIN="$INSTALL/Contents/MacOS/AudioCapture"
REOPEN=0
if pgrep -qf "$BIN"; then
  if defaults read io.github.lexreman.audiocapture inProgress >/dev/null 2>&1; then
    echo "Not installed: Audio Capture is recording. Run ./build.sh again once it is saved"
    exit 0
  fi
  osascript -e 'tell application id "io.github.lexreman.audiocapture" to quit' >/dev/null 2>&1
  for _ in {1..30}; do pgrep -qf "$BIN" || break; sleep 0.2; done
  if pgrep -qf "$BIN"; then echo "Not installed: Audio Capture did not quit"; exit 0; fi
  REOPEN=1
fi
rm -rf "$INSTALL" && ditto "$APP" "$INSTALL" && echo "Installed $INSTALL"
# An ad-hoc signature changes with every build, so macOS keeps a microphone grant that no longer matches
# and Include my voice would record silence. Reset it: the next voice recording asks again, cleanly.
if [[ -z "$IDENTITY" ]]; then tccutil reset Microphone io.github.lexreman.audiocapture >/dev/null 2>&1 && echo "Microphone permission reset: Include my voice turns off; right-click to turn it on and macOS asks again"; fi
if [[ $REOPEN == 1 ]]; then open "$INSTALL" && echo "Reopened"; fi
