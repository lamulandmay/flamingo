#!/bin/zsh
# Build the Flamingo product and assemble build/Flamingo.app. Usage: bundle.sh [debug|release]
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG=${1:-debug}
swift build -c $CONFIG --product Flamingo 2>&1 | grep -vE "Could not read priors"
APP=build/Flamingo.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/$CONFIG/Flamingo $APP/Contents/MacOS/Flamingo
cp Resources/Info.plist $APP/Contents/Info.plist
# SwiftPM resource bundles, if any module declares resources.
for b in .build/$CONFIG/*.bundle(N); do cp -R $b $APP/Contents/Resources/; done
# App icon from plan 08, once it exists.
for i in Resources/Assets/*.icns(N); do cp $i $APP/Contents/Resources/; done
codesign --force --options runtime --entitlements Resources/Flamingo.entitlements --sign - $APP
