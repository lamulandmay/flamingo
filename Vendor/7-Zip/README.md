# 7-Zip

`7zz`, the standalone console 7-Zip for macOS (universal), unmodified. Flamingo runs it to
expand RAR, 7z, CAB, ARJ, LZH, zstd and the other archives macOS can't, and any zip or tarball
the system tools fail on (encrypted, Deflate64). `scripts/bundle.sh` copies it to
`Flamingo.app/Contents/Helpers/7zz` and signs it with the app. `Unarchiver` in
`Sources/Flamingo/Unarchive.swift` is the only caller.

Version: 26.04
Source: https://github.com/ip7z/7zip (release assets), https://www.7-zip.org
SHA-256 of 7z2604-mac.tar.xz: bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578

License: GNU LGPL 2.1, with the unRAR restriction for the RAR decoder, and BSD for some code.
See `License.txt`, which ships in the app as `Contents/Resources/Licenses/7-Zip.txt`. The
source for this exact version is the tagged release in the repository above.

To update: `scripts/vendor-7zip.sh <version> <sha256 GitHub lists for 7z<ver>-mac.tar.xz>`.
