#!/bin/zsh
# Headless QA for the search results list (↩ in the palette with several files found).
# Runs a copy of build/Flamingo.app on a copy of fixtures/vault under its own bundle id
# (com.flamingo.qa-results), so the user's real settings are never touched, drives it with
# build/qa-post and saves screenshots. Usage: scripts/results-qa.sh <scratch-dir> [dark|light]
# Needs `scripts/bundle.sh debug` first. Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
# Names of its own, so a scratch dir shared with other QA runs is never clobbered.
APP=$SCR/FlamingoResultsQA.app VAULT=$SCR/results-vault-$LOOK LOG=$SCR/results-qa-$LOOK.log
BUNDLE_ID=com.flamingo.qa-results
CH=qa.results.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
launch() {
  # A placeholder key: the Keychain is never asked, so no prompt can land on the user's screen.
  ANTHROPIC_API_KEY=qa-placeholder FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH \
    $APP/Contents/MacOS/Flamingo -lastVault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep 5
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.6}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/results-$LOOK-$1.png; }
last() { grep "$1" $LOG | tail -${2:-1}; }
check() { if last "$2" | grep -q -- "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; fi }
status() { Q results status; sleep 0.2; }

launch
Q briefing close
Q window 1200 760
sleep 3   # the index lists the vault

echo "R1 ⌘K arc ↩: several files, so the list"
Q key 40 cmd; Q type arc; sleep 2
Q key 36; sleep 2
status; shot list
check "R1 list shown" "results: shown" "shown=true"
check "R1 several rows" "results: shown" "rows=[2-9]"
check "R1 keyboard in the list" "results: shown" "responder=ResultsTableView"

echo "R2 header sort, both ways"
Q results sort name; status; shot sort-name
check "R2 name ascending" "results: shown" "sort=name asc"
Q results sort name; status; shot sort-name-desc
check "R2 name descending" "results: shown" "sort=name desc"
Q results sort modified; status
check "R2 dates newest first" "results: shown" "sort=modified desc"
Q results menu relevance; status
check "R2 relevance from the menu" "results: shown" "sort=relevance"
Q results menu added; status; shot sort-added
check "R2 Date Added from the menu" "results: shown" "sort=added desc"

echo "R3 Kind filter"
Q results kind images; status; shot kind-images
check "R3 images only" "results: shown" "kind=images"
last "results: shown" | sed 's/.*first=/first=/'
Q results kind all; status

echo "R4 ↓ ↩ opens, ⌘[ comes back as left, ⌘] forward"
Q results sort name
Q key 125; Q key 125; status
SEL=$(last "results: shown" | sed 's/.*selection=\([^ ]*\) .*/\1/')
echo "     selected $SEL"
Q key 36; sleep 1.5; status; shot opened
check "R4 file open" "results: shown" "shown=false"
Q key 33 cmd; sleep 1.5; status; shot back
check "R4 back to the list" "results: shown" "shown=true"
check "R4 order kept" "results: shown" "sort=name asc"
check "R4 selection kept" "results: shown" "selection=$SEL"
Q key 30 cmd; sleep 1.5; status
check "R4 forward to the file" "results: shown" "shown=false"
Q key 33 cmd; sleep 1.5

echo "R5 the field refines the list"
Q results field; Q key 51; Q key 51; Q key 51; Q type pricing; sleep 1.5; status; shot refined
check "R5 query edited" "results: shown" "query=pricing"

echo "R6 Esc goes back"
Q results field; Q key 125; sleep 0.5
Q key 53; sleep 1; status
last "results: shown" | sed 's/.*shown=\([a-z]*\).*/     shown=\1/'

echo "R6b no matches"
Q results query zzqqxxv; sleep 1.5; status; shot empty
check "R6b nothing listed" "results: shown" "rows=0"

echo "R6c ↩ before the rows land waits for them"
Q key 40 cmd; W=0.02 Q type pricing; W=0.02 Q key 36; sleep 2.5; status
check "R6c list for pricing" "results: shown" "shown=true query=pricing"

# Space (Quick Look) is left out: the panel can't take part from a background app, and it
# would show on the user's screen.

echo "R7 one result opens directly"
Q key 40 cmd; Q type moodboard; sleep 2; Q key 36; sleep 1.5; status
check "R7 opened, no list" "results: shown" "selected=design/moodboard.jpg"

echo "R8 the search tab's ↩"
Q menu Search in All Files; sleep 0.8; Q type launch; sleep 1.5; Q key 36; sleep 2; status; shot sidebar
check "R8 list from the sidebar" "results: shown" "shown=true"

echo "R10 tiled: the list shows in the pane that asked"
Q key 53; sleep 0.5
Q tile halves; sleep 1.2
Q key 40 cmd; Q type arc; sleep 2; Q key 36; sleep 2; status; shot tiled
check "R10 list in a tile" "results: shown" "shown=true query=arc"
Q tile single; sleep 1

echo "R9 1000×600"
Q window 1000 600; sleep 1; shot narrow
echo "lag:"; grep "worst lag" $LOG | tail -2
quit
echo "log: $LOG"
