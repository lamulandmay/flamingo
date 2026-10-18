#!/bin/zsh
# Navigation QA: the file explorer following the open file, "reveal current file", and
# two-finger swipes (gesture decisions on posted events, AppKit's side simulated).
# Runs a copy of build/Flamingo.app under its own bundle id on a copy of fixtures/vault grown
# with 30 more folders, a deep path and a folder at the end, so rows can be off screen.
# Usage: scripts/nav-qa.sh <scratch-dir> [dark|light]   (SLOWMO=6 for the pulse and arrival shots)
# Needs `scripts/bundle.sh debug` first. Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
[[ build/qa-scroll -nt scripts/qa-scroll.swift ]] || swiftc -O -o build/qa-scroll scripts/qa-scroll.swift
APP=$SCR/FlamingoNavQA.app VAULT=$SCR/vault-nav LOG=$SCR/nav-$LOOK.log
BUNDLE_ID=com.flamingo.qa-nav
CH=qa.nav.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
for i in $(seq -w 1 30); do mkdir -p $VAULT/area-$i; print "area $i" > $VAULT/area-$i/note-$i.md; done
mkdir -p $VAULT/projects/2026/q4/launch/assets/final
print "deep" > $VAULT/projects/2026/q4/launch/assets/final/deep-note.md
mkdir -p $VAULT/zz-late; for i in 1 2 3 4 5; do print "late $i" > $VAULT/zz-late/late-$i.md; done
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
# ANTHROPIC_API_KEY keeps the copy away from the Keychain (a prompt would hang it).
launch() {
  FLAMINGO_SLOWMO=${SLOWMO:-1} ANTHROPIC_API_KEY=qa-placeholder FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH \
    $APP/Contents/MacOS/Flamingo -lastVault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep 4.5
  Q briefing close; Q window 1200 760
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.6}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$LOOK-$1.png; }
last() { grep -a "$1" $LOG | tail -${2:-1}; }
check() { if last "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; fi }
status() { Q sidebar status; }
# A two-finger gesture posted to the copy: fx fy (window fractions) dx dy steps [ms] [began-dx began-dy]
gesture() {
  local b=(${(s:,:)$(build/window-id --bounds --pid $PID Flamingo)}) fx=$1 fy=$2; shift 2
  build/qa-scroll $PID $(( b[1] + b[3] * fx )) $(( b[2] + b[4] * fy )) "$@"
  sleep 1.2
}

echo "N0 a follow switched off by the old crosshair comes back on, once"
defaults write $BUNDLE_ID autoReveal -bool false
launch
[[ "$(defaults read $BUNDLE_ID autoReveal 2>&1)" == *"does not exist"* || "$(defaults read $BUNDLE_ID autoRevealCrosshairReset)" == 1 ]] \
  && echo "ok   N0 reset" || echo "FAIL N0 autoReveal still $(defaults read $BUNDLE_ID autoReveal)"

echo "N1 every way of opening a file: the explorer selects it and it shows"
Q sidebar idle
for step in "nav graph zz-late/late-2.md" "nav link deep-note" "nav browse area-05/note-05.md" "nav recent zz-late/late-3.md" \
            "nav back" "nav back" "nav forward" "open area-01/note-01.md"; do
  Q $step; sleep 0.5; status
  want=$(last "qa: sidebar tab" | sed 's/.*selected=\([^ ]*\).*/\1/')
  check "N1 $step" "qa: sidebar tab" "id=$want visible"
done
shot follow
Q tile halves; sleep 1; Q nav pane 2 area-07/note-07.md; sleep 0.5; status; check "N1 another pane" "qa: sidebar tab" "id=area-07/note-07.md visible"
Q pane 1; sleep 0.5; status; check "N1 back to the first pane" "qa: sidebar tab" "id=area-01/note-01.md visible"
Q tile single; sleep 0.8

echo "N2 a hidden row comes to about the middle; a visible one stays put"
Q sidebar scroll 0; Q open zz-late/late-1.md; sleep 0.6; status
check "N2 centred-ish or at the list's end" "qa: sidebar tab" "id=zz-late/late-1.md visible at=0\.[4-9]"
Y1=$(last "qa: sidebar tab" | sed 's/.* y=\([-0-9]*\).*/\1/')
Q open zz-late/late-2.md; sleep 0.6; status
Y2=$(last "qa: sidebar tab" | sed 's/.* y=\([-0-9]*\).*/\1/')
[[ $Y1 == $Y2 ]] && echo "ok   N2 visible row: no scroll" || echo "FAIL N2 scrolled $Y1 → $Y2"

echo "N3 from Search or Bookmarks, folded: back in Files the open file shows"
Q sidebar tab search; Q open area-25/note-25.md; Q sidebar tab files; sleep 1; status
check "N3 search → files" "qa: sidebar tab" "id=area-25/note-25.md visible"
Q sidebar tab bookmarks; Q open area-02/note-02.md; Q sidebar tab files; sleep 1; status
check "N3 bookmarks → files" "qa: sidebar tab" "id=area-02/note-02.md visible"
Q sidebar fold; Q open projects/2026/q4/launch/assets/final/deep-note.md; Q sidebar unfold; sleep 1; status
check "N3 folded → unfolded, deep path" "qa: sidebar tab" "final/deep-note.md visible"
shot after-tabs

echo "N4 a file made a moment ago is found"
print fresh > $VAULT/area-09/fresh.md; Q open area-09/fresh.md; sleep 0.4; status
check "N4 fresh file" "qa: sidebar tab" "id=area-09/fresh.md visible"

echo "N5 reveal current file: scrolled away, from Search, with nothing open"
Q open zz-late/late-4.md; Q sidebar scroll 0; W=1.2 Q nav reveal; shot reveal-pulse; status
check "N5 reveal" "qa: sidebar tab" "id=zz-late/late-4.md visible"
Q sidebar tab search; W=1.2 Q nav reveal; status
check "N5 reveal from search" "qa: sidebar tab" "tab=files .*id=zz-late/late-4.md visible"
Q menu as Columns; sleep 1; shot no-file

echo "S1 gestures on the monitor's real path (posted events)"
# The graph first: a view change is a history entry of its own.
Q key 19 cmd; sleep 1.5
gesture 0.6 0.5 8 0 6;             check "S1 the graph pans" "swipe: began" "the view pans"
Q key 18 cmd; sleep 1
Q open area-03/note-03.md; Q open area-04/note-04.md
gesture 0.6 0.5 0 -8 10;           check "S1 vertical scrolls" "swipe: began" "vertical"
gesture 0.6 0.5 -8 0 10;           check "S1 nothing forward" "swipe: began" "nothing forward"
gesture 0.6 0.5 6 1 10 12 0 0;     check "S1 still began, then sideways" "swipe: tracking" "tracking back"
sleep 1
# Posted events can't move AppKit's amount past the first event's, so it cancels; how it ends is the point.
check "S1 AppKit lifts, settles with no phase, completes" "swipe: #1 amount" "none complete"
check "S1 a cancelled swipe stays put" "swipe: cancelled" "cancelled"

echo "S2 AppKit's side simulated: held at the threshold, then lifted"
Q nav status; BEFORE=$(last "qa: nav status" | sed 's/.*index=\([0-9]*\).*/\1/')
W=0.8 Q swipe sim back 0.2,0.5,0.8,1.0,1.06 hold; shot swipe-ready
check "S2 one tap at the threshold" "swipe: ready" "tap"
W=${ARRIVAL_SHOT:-0.45} Q swipe lift ended; shot swipe-arrival; sleep 1; check "S2 commits" "swipe: commit" "commit back"
Q nav status; AFTER=$(last "qa: nav status" | sed 's/.*index=\([0-9]*\).*/\1/')
(( AFTER == BEFORE - 1 )) && echo "ok   S2 one step back" || echo "FAIL S2 index $BEFORE → $AFTER"
status; check "S2 the explorer follows the swipe" "qa: sidebar tab" "id=area-03/note-03.md visible"
W=1.2 Q swipe sim back 0.2,0.4 cancelled; check "S2 a short swipe cancels" "swipe: cancelled" "cancelled"
Q nav status; check "S2 nothing moved" "qa: nav status" "index=$AFTER "

echo "N6 follow turned off (in Settings): no stale highlight, the button still reveals"
quit; defaults write $BUNDLE_ID autoReveal -bool false; launch
Q open area-06/note-06.md; Q sidebar idle; Q nav graph zz-late/late-5.md; sleep 0.6; status
check "N6 nothing highlighted elsewhere" "qa: sidebar tab" "row=-1"
W=1.2 Q nav reveal; status; check "N6 reveal still works" "qa: sidebar tab" "id=zz-late/late-5.md visible"
[[ "$(defaults read $BUNDLE_ID autoReveal)" == 0 ]] && echo "ok   N6 the setting stays off" || echo "FAIL N6 reset again"
echo "lag:"; grep -a "worst lag" $LOG | tail -3
quit
echo "log: $LOG"
