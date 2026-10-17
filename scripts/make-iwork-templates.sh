#!/bin/zsh
# Development-only: Keynote, Pages and Numbers each save one blank document into
# Sources/FlamingoCore/Templates (Blank.key, Blank.pages, Blank.numbers). Only the apps can
# write their formats. They launch in the background, and nothing else of yours is closed.
set -e -o pipefail
cd "$(dirname "$0")/.."
out="$PWD/Sources/FlamingoCore/Templates"
tmp=$(mktemp -d)
for pair in com.apple.iWork.Keynote:key com.apple.Pages:pages com.apple.iWork.Numbers:numbers; do
  id=${pair%%:*} ext=${pair##*:}
  osascript -e "with timeout of 90 seconds
tell application id \"$id\"
  launch
  set d to make new document
  save d in POSIX file \"$tmp/Blank.$ext\"
  close d saving no
end tell
end timeout"
  # Copy without the apps' extended attributes (quarantine, document UUID).
  cat "$tmp/Blank.$ext" > "$out/Blank.$ext"
done
rm -rf "$tmp"
