#!/bin/zsh
# Refresh Vendor/7-Zip from an official 7-Zip release. Usage: vendor-7zip.sh <version> <sha256>
# e.g. vendor-7zip.sh 26.04 bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578
# The digest is the one GitHub lists for 7z<ver>-mac.tar.xz on github.com/ip7z/7zip/releases.
set -e -o pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?version, e.g. 26.04}
SHA=${2:?sha256 of the release tarball}
NAME=7z${VERSION//./}-mac.tar.xz
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
curl -sSfL -o $WORK/$NAME https://github.com/ip7z/7zip/releases/download/$VERSION/$NAME
echo "$SHA  $WORK/$NAME" | shasum -a 256 -c -
mkdir $WORK/x
tar -xJf $WORK/$NAME -C $WORK/x
cp $WORK/x/7zz $WORK/x/License.txt Vendor/7-Zip/
sed -i '' "s/^Version: .*/Version: $VERSION/; s/^SHA-256 of .*/SHA-256 of $NAME: $SHA/" Vendor/7-Zip/README.md
Vendor/7-Zip/7zz i | head -2
