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
cp Info.plist "$APP/Contents/"
codesign -s "${SIGN_ID:--}" --force "$APP"
echo "$APP"
