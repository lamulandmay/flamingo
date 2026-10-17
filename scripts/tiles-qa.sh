#!/bin/zsh
# Headless QA for ••• pane tiling and launchers (plan 14, steps B1–B10). Runs a copy of
# build/Flamingo.app on a copy of fixtures/vault under its own bundle id (com.flamingo.qa-tiles),
# so the user's real settings are never touched, drives it with build/qa-post and saves screenshots.
# Usage: scripts/tiles-qa.sh <scratch-dir> [dark|light]
# Needs `scripts/bundle.sh debug` first. Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
APP=$SCR/FlamingoQA.app VAULT=$SCR/vault-$LOOK LOG=$SCR/qa-$LOOK.log
BUNDLE_ID=com.flamingo.qa-tiles
CH=qa.tiles.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
launch() {
  FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH $APP/Contents/MacOS/Flamingo -lastVault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep 4.5
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.6}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$LOOK-$1.png; }
last() { grep "$1" $LOG | tail -${2:-1}; }
check() { if last "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; fi }

launch
Q window 1200 760
echo "single, with •••"
Q open decks/q3-board-review.pptx; sleep 1; shot single

echo "B1 three columns: launchers in panes 2 and 3 with different picks"
Q open notes/pricing-decisions.md
Q tile thirds; sleep 2.2; shot thirds
check "B1 layout" "tiles: layout" "layout=thirds"
check "B1 thirds at 1200 folds the inspector" "tiles: panels" 'hide=\["inspector"\]'
last "launcher: picks" 2
S1=$(last "launcher: picks slot=1" | sed 's/.*picks slot=1 //'); S2=$(last "launcher: picks slot=2" | sed 's/.*picks slot=2 //')
[[ -n $S1 && $S1 != $S2 ]] && echo "ok   B1 launchers differ" || echo "FAIL B1 launchers show the same picks"

echo "B2 launch 2 #0: pane 2 opens its top pick; pane 3's picks update"
Q launch 2 '#0'; sleep 2; shot after-pick
check "B2 pane 2 filled" "tiles: " "layout=thirds"
last "launcher: picks slot=1" 1

echo "B3 launch 3 q3: fuzzy at once, semantic later"
Q pane 3; Q launch 3 q3; sleep 0.3; shot launcher-typing; sleep 1.5
last "launcher: results" 3

echo "B4 ⌥⌘→ ×3 walks the panes and wraps"
Q key 124 cmd opt; Q key 124 cmd opt; Q key 124 cmd opt
last "tiles: focus" 3 | sed 's/files=.*//'

echo "B5 ⌘W on the middle pane gives halves"
Q pane 2; Q key 13 cmd; sleep 0.6; shot closed
check "B5 halves" "tiles: close" "layout=halves"
echo "B6 undo brings back thirds"
Q workspace undo; sleep 0.8; shot undone
check "B6 thirds again" "tiles: restored" "layout=thirds"

echo "B7 four, then one and two"
Q menu "Four"; sleep 1.5; shot grid
Q menu "One and Two"; sleep 1.2; shot one-and-two
Q menu "Two Side by Side"; sleep 0.6

echo "B7b back to single restores the inspector"
Q tile thirds; sleep 1.2; Q tile single; sleep 1; shot single-after
check "B7b inspector back" "tiles: panels" 'restore=\["inspector"\]'

echo "B8 relaunch: layout, panes and active pane come back"
Q tile thirds; sleep 1; Q launch 2 '#1'; sleep 1.5
last "tiles:" 1 | sed 's/files=.*//'
BEFORE=$(last "tiles:" 1 | sed 's/.*tiles: [a-z]* //')
sleep 1; quit; launch; sleep 1
echo "before: $BEFORE"; last "tiles: restored" 1 | sed 's/.*tiles: restored //'
[[ "$(last 'tiles: restored' 1 | sed 's/.*tiles: restored //')" == "${BEFORE}" ]] && echo "ok   B8 same layout, panes and active pane" || echo "FAIL B8 differs"
shot restored

echo "B9 legacy two-pane snapshot restores to halves"
quit
KEY="workspace.${VAULT#/private}"   # the app standardizes /private/tmp to /tmp
JSON='{"mode":0,"anchors":{},"openFiles":[{"relativePath":"notes/pricing-decisions.md"},{"relativePath":"finance/q3-model.xlsx"}],"history":{"places":[],"index":-1},"split":{"visible":true,"activePane":"secondary","primary":{"file":{"relativePath":"notes/pricing-decisions.md"},"anchors":{},"readSource":false},"secondary":{"file":{"relativePath":"finance/q3-model.xlsx"},"anchors":{},"readSource":false}}}'
defaults write $BUNDLE_ID $KEY -data "$(print -rn -- $JSON | xxd -p | tr -d '\n')"
launch; sleep 1
check "B9 legacy" "tiles: restored" "layout=halves"
shot legacy

echo "B10 every layout at 1000×600 and full screen"
for size in "1000 600" "full"; do
  Q window $size; sleep 1
  for layout in single halves thirds mainPlusStack grid; do
    Q tile $layout; sleep 1.2; shot ${layout}-${size// /x}
  done
done
echo "lag:"; grep "worst lag" $LOG | tail -3
quit
echo "log: $LOG"
