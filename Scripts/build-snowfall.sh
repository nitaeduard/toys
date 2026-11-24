#!/bin/bash
# Builds Snowfall with Xcode 27, applying Config/Local.xcconfig (signing team,
# bundle ID), then restarts it. Usage: Scripts/build-snowfall.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
LOCAL=Config/Local.xcconfig
[ -f "$LOCAL" ] || { echo "Missing $LOCAL — copy Config/Local.example.xcconfig and fill it in." >&2; exit 1; }

# Use Xcode 27 for the new project format, even if xcode-select points elsewhere.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for x in /Applications/Xcode27*.app /Volumes/*/Applications/Xcode27*.app /Applications/Xcode.app; do
    if [ -d "$x" ] && [[ "$(defaults read "$x/Contents/Info" CFBundleShortVersionString)" == 27* ]]; then
      export DEVELOPER_DIR="$x/Contents/Developer"; break
    fi
  done
fi

xcodebuild -project Toys.xcodeproj -scheme Snowfall -configuration "$CONFIG" \
  -xcconfig "$LOCAL" -derivedDataPath build/DerivedData build | grep -E "error|warning: [^M]|BUILD" || true

APP="build/DerivedData/Build/Products/$CONFIG/Snowfall.app"
[ -d "$APP" ] || exit 1
pkill -x Snowfall || true
sleep 1
open "$APP"
echo "Running $APP"
