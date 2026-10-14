#!/bin/zsh
# Screenshot every mode of a running Flamingo into docs/screens/.
# Drives the app with System Events keystrokes (the terminal needs Accessibility and
# Screen Recording). Run `make demo` first. Usage: screens.sh [suffix]
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
OUT=docs/screens
SUFFIX=${1:+-$1}
mkdir -p $OUT build
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift

key() {  # key <keystroke or key code> [modifiers]
  osascript -e 'tell application "Flamingo" to activate' \
            -e "tell application \"System Events\" to $1" >/dev/null
  sleep ${2:-0.8}
}
shot() {
  local id=$(build/window-id Flamingo) || { echo "no Flamingo window" >&2; exit 1; }
  screencapture -o -x -l $id "$OUT/$1$SUFFIX.png"
  echo "$OUT/$1$SUFFIX.png"
}

key 'keystroke "1" using command down'
key 'key code 125'                       # down arrow: select the first file
key 'key code 125' 2.5                   # second file; give Quick Look time to render
shot files
key 'keystroke "2" using command down' 2
shot graph
key 'keystroke "3" using command down' 1.5
shot trail
key 'keystroke "4" using command down' 1.5
shot ask
key 'keystroke "1" using command down'
key 'keystroke "k" using command down'
shot palette
key 'key code 53'                        # Esc
key 'keystroke "c" using {command down, shift down}'
shot capture
key 'key code 53'
