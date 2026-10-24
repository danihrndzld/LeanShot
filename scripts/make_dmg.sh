#!/bin/sh
# Builds a signed LeanShot.app and packs it in a signed drag-to-Applications DMG: scripts/make_dmg.sh
# SIGN_ID defaults to the first codesigning identity in the keychain. A "Developer ID Application"
# identity plus `xcrun notarytool` is what removes the Gatekeeper prompt on other Macs.
set -e
cd "$(dirname "$0")/.."
export SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 {print $2}')}
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
cp -R build/LeanShot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/LeanShot-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "LeanShot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign -s "$SIGN_ID" --timestamp=none --force "$DMG"
codesign --verify --verbose=1 build/LeanShot.app "$DMG"
echo "$DMG signed with $SIGN_ID"
