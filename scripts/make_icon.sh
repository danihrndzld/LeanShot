#!/bin/sh
# Compiles Resources/LeanShot.icon (edit it in Icon Composer) into Resources/Assets.car + LeanShot.icns.
# Needs Xcode 26+; build.sh only copies the compiled output, so builds work with Command Line Tools alone.
set -e
cd "$(dirname "$0")/.."
DEV=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | tail -1)/Contents/Developer}
OUT=$(mktemp -d)
DEVELOPER_DIR="$DEV" "$DEV/usr/bin/actool" Resources/LeanShot.icon --compile "$OUT" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon LeanShot --output-partial-info-plist "$OUT/partial.plist" >/dev/null
cp "$OUT/Assets.car" "$OUT/LeanShot.icns" Resources/
rm -rf "$OUT"
echo "wrote Resources/Assets.car and Resources/LeanShot.icns"
