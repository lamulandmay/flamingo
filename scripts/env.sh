# Source this (or let scripts/build.sh, test.sh, run.sh do it).
# SwiftUI's macro plugin ships with Xcode, not the Command Line Tools, so point at an Xcode.
# Prefers Xcode-beta (what this was built with), then Xcode, then whatever xcode-select says.
if [[ -z "$DEVELOPER_DIR" ]]; then
  for x in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d $x/Contents/Developer ]] && { export DEVELOPER_DIR=$x/Contents/Developer; break; }
  done
fi
# No Xcode found and xcode-select points at the Command Line Tools: the build would fail later
# on SwiftUI macros with an error that never mentions Xcode, so stop here and say why.
if [[ -z "$DEVELOPER_DIR" && "$(xcode-select -p 2>/dev/null)" == */CommandLineTools* ]]; then
  echo "error: Flamingo needs Xcode (SwiftUI macros); the Command Line Tools alone can't build it." >&2
  echo "       Install Xcode, or set DEVELOPER_DIR to one (e.g. /Applications/Xcode.app/Contents/Developer)." >&2
  return 1 2>/dev/null || exit 1
fi
