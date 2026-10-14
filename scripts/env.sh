# Source this (or let scripts/build.sh, test.sh, run.sh do it).
# SwiftUI's macro plugin ships with Xcode, not the Command Line Tools, so point at an Xcode.
# Prefers Xcode-beta (what this was built with), then Xcode, then whatever xcode-select says.
if [[ -z "$DEVELOPER_DIR" ]]; then
  for x in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d $x/Contents/Developer ]] && { export DEVELOPER_DIR=$x/Contents/Developer; break; }
  done
fi
