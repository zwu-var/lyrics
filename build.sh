#!/bin/bash
# Builds build/LyricsBar.app. Run it with: open build/LyricsBar.app
set -euo pipefail
cd "$(dirname "$0")"

app=build/LyricsBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -swift-version 6 -o "$app/Contents/MacOS/LyricsBar" Sources/*.swift "$@"

# Sign the whole bundle (ad-hoc) so Info.plist is sealed into the signature. macOS remembers the Automation
# permission by code signature, and an ad-hoc signature changes on every build.
codesign --force --sign - "$app"
echo "Built $app"
