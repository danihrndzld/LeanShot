#!/bin/sh
# Builds build/LeanShot.app. Set SIGN_ID to a stable codesigning identity so the
# Screen Recording grant survives rebuilds (ad-hoc "-" changes every build).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/LeanShot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LeanShot "$APP/Contents/MacOS/"
# SwiftPM records SDK 14.0 in the binary, which keeps AppKit in its pre-Liquid Glass compatibility look.
# Stamp the real SDK so macOS 26+ renders native glass toolbars, sidebars and controls.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/LeanShot" "$APP/Contents/MacOS/LeanShot"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Resources/Assets.car Resources/LeanShot.icns "$APP/Contents/Resources/"
codesign -s "${SIGN_ID:--}" --force "$APP"
echo "$APP"
