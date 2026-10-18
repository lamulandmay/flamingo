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
# Plan 08's icon, asset catalog (AppIcon, AccentColor) and menu bar template. Not its sources.
for i in AppIcon.icns Assets.car MenuBarIconTemplate.png MenuBarIconTemplate@2x.png; do
  [[ -f Resources/Assets/$i ]] && cp Resources/Assets/$i $APP/Contents/Resources/
done
# 7-Zip expands the archives macOS can't (Vendor/7-Zip/README.md); its license goes with it.
mkdir -p $APP/Contents/Helpers $APP/Contents/Resources/Licenses
cp Vendor/7-Zip/7zz $APP/Contents/Helpers/7zz
cp Vendor/7-Zip/License.txt $APP/Contents/Resources/Licenses/7-Zip.txt
# A real identity keeps the designated requirement stable across builds, so Accessibility
# and Automation grants survive a rebuild. Ad-hoc changes it every time.
# FLAMINGO_SIGN_IDENTITY=- forces ad-hoc.
IDENTITY=${FLAMINGO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
# Nested code is signed before the app seals it.
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" $APP/Contents/Helpers/7zz
codesign --force --options runtime --timestamp=none --entitlements Resources/Flamingo.entitlements \
  --sign "${IDENTITY:--}" $APP
