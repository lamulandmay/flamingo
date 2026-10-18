#!/bin/zsh
# Headless QA for the hold-⌥⇧ recent-files ring (plan 14, steps A1–A8). Runs a copy of
# build/Flamingo.app on a copy of fixtures/vault under its own bundle id, so the user's real
# settings are never touched, drives it with build/qa-post and saves screenshots.
# Usage: scripts/radial-qa.sh <scratch-dir> [dark|light] [files-to-open (default 10)]
# Needs `scripts/bundle.sh debug` first. Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
SCR=${1:?scratch dir}; LOOK=${2:-dark}; COUNT=${3:-10}
mkdir -p build
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
TAG=$LOOK-$COUNT
APP=$SCR/FlamingoQA.app VAULT=$SCR/vault-$TAG LOG=$SCR/qa-$TAG.log
CH=qa.radial.$$
rm -rf $APP $VAULT; mkdir -p $SCR
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
# The fixture ships a trail; with few files to open, start from an empty one so the ring has 4 compass slots.
(( COUNT <= 4 )) && rm -f $VAULT/.flamingo/trail.jsonl
# Its own bundle id means its own UserDefaults domain.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.flamingo.qa-radial" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete com.flamingo.qa-radial >/dev/null 2>&1

FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH FLAMINGO_SLOWMO=${SLOWMO:-1} $APP/Contents/MacOS/Flamingo \
  -lastVault $VAULT -FlamingoAppearance $LOOK > $LOG 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.5}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$TAG-$1.png; }
count() { grep -c "$1" $LOG; }
sleep 4

FILES=(decks/q3-board-review.pptx finance/q3-model.xlsx notes/pricing-decisions.md docs/pricing-memo.docx
       design/arc-render.png legal/supplier-agreement.pdf research/market-sizing.pdf notes/launch-checklist.md
       decks/arc-launch-plan.pptx finance/unit-economics.xlsx docs/arc-product-brief.docx notes/open-questions.md)
echo "A1 open $COUNT files"
for f in ${FILES[1,$COUNT]}; do W=1.3 Q open $f; done
W=1.5 Q open ${FILES[$COUNT]}   # the last is the active file, left out of the ring
Q radial origin 560 380

echo "A2 hold: ring opens"
Q flags opt shift; sleep 0.8; shot ring-open
grep "radial:" $LOG | tail -4
echo "A3 flick right"
Q radial 90; sleep 0.4; shot ring-slot
Q radial 0;  sleep 0.4; shot ring-slot-top
Q radial 90
echo "A4 release: commits"
BEFORE=$(count "radial: commit")
Q flags none; sleep 0.8; shot after-commit
grep "radial: commit" $LOG | tail -1
echo "A5 a key within the hold delay (⌥⇧I) cancels and goes on to the app"
W=0.05 Q flags opt shift; Q key 34 opt shift; sleep 0.5; shot after-key
Q flags none
grep "radial:" $LOG | tail -3
echo "A6 Esc closes and keeps the file"
Q flags opt shift; sleep 0.8; Q radial 90; Q key 53; Q flags none; sleep 0.5
grep "radial:" $LOG | tail -4
echo "A7 release in the dead zone opens nothing"
Q flags opt shift; sleep 0.8; Q radial center; Q flags none; sleep 0.5
grep "radial:" $LOG | tail -3
echo "lag:"; grep "worst lag" $LOG | tail -3
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "log: $LOG"
