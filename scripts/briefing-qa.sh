#!/bin/zsh
# Headless QA for the morning inbox (plan 17, section 4 and 5). Runs a copy of build/Flamingo.app on a
# seeded copy of fixtures/vault under its own bundle id (com.flamingo.qa-briefing) and defaults suite,
# drives it with build/qa-post and saves screenshots.
# Usage: scripts/briefing-qa.sh <scratch-dir> [dark|light]     Needs `scripts/bundle.sh debug` first.
# Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
APP=$SCR/FlamingoQA.app VAULT=$SCR/vault-$LOOK LOG=$SCR/qa-$LOOK.log
BUNDLE_ID=com.flamingo.qa-briefing
CH=qa.briefing.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -Rp fixtures/vault $VAULT
scripts/briefing-seed.sh $VAULT >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
launch() {
  FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH FLAMINGO_FAKE_LLM=1 FLAMINGO_DEFAULTS_SUITE=$BUNDLE_ID \
    $APP/Contents/MacOS/Flamingo --vault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep ${1:-6}
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.7}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$LOOK-$1.png; }
last() { grep "$1" $LOG | tail -${2:-1}; }
bounds() { build/window-id --bounds --pid $PID Flamingo; }
check() { if last "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; fi }

echo "== launch: the first open of the day zooms the window by itself"
launch 3
echo "before zoom: $(bounds)"
sleep 4
echo "zoomed:      $(bounds)"
last "qa: briefing " 3
check "launch opened" "qa: briefing memos" "memos=3"
sleep 1; shot hero-zoomed

echo "== status, visible frame"
Q briefing status; last "briefing status" 1

echo "== Esc restores the frame"
Q briefing key esc; sleep 0.8
echo "restored:    $(bounds)"
check "restored" "briefing restore" "frame="
Q briefing status; last "briefing status" 1

echo "== second open of the day does not zoom"
Q briefing; sleep 1.2; shot manual-open
echo "no-zoom:     $(bounds)"
Q briefing close; sleep 0.6

echo "== the ring does not open over the briefing"
Q briefing; sleep 1.2
N=$(grep -c "radial: open" $LOG); W=1 Q flags opt shift; Q flags none
[[ $(grep -c "radial: open" $LOG) == $N ]] && echo "ok   no ring while the briefing is up" || echo "FAIL ring opened over the briefing"
Q briefing close; sleep 0.6

echo "== 1000x600"
Q window 1000x600; sleep 0.8; Q briefing; sleep 1.2; shot compact-1000x600
Q briefing close; sleep 0.6; Q window 1200x760

echo "== triage: j, e (done)"
Q briefing; sleep 1
Q briefing key j; Q briefing key e; sleep 0.18; shot done-flash; sleep 0.8; shot after-done
last "briefing" 1
Q briefing key s; sleep 1; shot after-snooze
echo "== undo"
Q workspace undo; sleep 1; shot after-undo
echo "== memo reader"
Q briefing select 1; Q briefing key return; sleep 1; shot memo-reader
Q briefing key esc; sleep 0.5
Q briefing close; sleep 0.5

echo "== reply"
Q briefing; sleep 1; Q briefing key r; sleep 1; shot reply-field
Q briefing key esc; sleep 0.5
Q briefing close; sleep 0.5

echo "== relaunch the same day: no second briefing"
N=$(grep -c "qa: briefing memos" $LOG); quit; launch 8
[[ $(grep -c "qa: briefing memos" $LOG) == $N ]] && echo "ok   no second briefing on relaunch" || echo "FAIL relaunch opened it again"
shot relaunch
quit
echo "lag:"; grep "worst lag" $LOG | tail -3
echo "log: $LOG"
