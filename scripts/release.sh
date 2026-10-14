#!/bin/zsh
# Release build, bundled and zipped to build/Flamingo.zip.
set -e -o pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release
rm -f build/Flamingo.zip
ditto -c -k --keepParent build/Flamingo.app build/Flamingo.zip
echo "build/Flamingo.zip  $(du -h build/Flamingo.zip | cut -f1)"
