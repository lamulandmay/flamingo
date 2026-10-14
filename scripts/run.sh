#!/bin/zsh
# Build and launch Flamingo as a real .app bundle so Quick Look, menus and
# Accessibility prompts behave. Plan 10 owns; everyone may use.
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG=${1:-debug}
swift build -c $CONFIG --product Flamingo
APP=build/Flamingo.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/$CONFIG/Flamingo $APP/Contents/MacOS/Flamingo
[ -f Resources/Info.plist ] && cp Resources/Info.plist $APP/Contents/Info.plist || cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.flamingo.app</string>
<key>CFBundleName</key><string>Flamingo</string>
<key>CFBundleExecutable</key><string>Flamingo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
[ -d Resources/Assets ] && cp -R Resources/Assets/* $APP/Contents/Resources/ 2>/dev/null || true
codesign --force --sign - $APP >/dev/null 2>&1 || true
open $APP
