#!/bin/zsh
# The headline scenario, end to end, with the fake local model (FLAMINGO_FAKE_LLM=1):
#   evening  17:30  a thought on slide 7 of the board deck: "review conflict between this and [[q3-model.xlsx]] before friday"
#            -> uid, then (fake understanding) kind intent, action review-conflict
#   night    02:00  `nightshift now` -> memo in .flamingo/work/<day>/ with verdict conflict and a
#            "Where they disagree" row citing slide 7 "$249" vs the Assumptions sheet "229", plus the AI reply with `work`
#   morning  08:30  the first open of the day zooms the inbox with that memo as a card; Return opens the MemoReader.
# Usage: scripts/headline-qa.sh <scratch-dir> [dark|light]     Needs `scripts/bundle.sh debug` first.
# Runs a copy of build/Flamingo.app under its own bundle id (com.flamingo.qa-headline) on a fresh copy of
# fixtures/vault. Only the copy's own pid is ever killed. Screenshots land in <scratch>/<look>-*.png.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
APP=$SCR/FlamingoQA.app VAULT=$SCR/vault-$LOOK LOG=$SCR/qa-$LOOK.log
BUNDLE_ID=com.flamingo.qa-headline
CH=qa.headline.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
launch() {
  FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH FLAMINGO_FAKE_LLM=1 FLAMINGO_FAKE_LLM_DIR=$ROOT/fixtures/fake-llm FLAMINGO_DEFAULTS_SUITE=$BUNDLE_ID \
    $APP/Contents/MacOS/Flamingo -lastVault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep 5
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.8}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$LOOK-$1.png; }
last() { grep "$1" $LOG | tail -${2:-1}; }
check() { if last "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; FAILED=1; fi }
FAILED=0
SIDECAR="$VAULT/.flamingo/notes/decks/q3-board-review.pptx.md"

wait_index() {
  Q key 40 cmd; Q type zz
  for i in {1..40}; do
    grep "palette:" $LOG | tail -1 | grep -q "Checking every file" || break
    Q type z; sleep 3
  done
  Q key 53; sleep 0.4
}

launch
Q window 1200 760
wait_index
Q briefing close; sleep 1.2   # launch is a first open of the real day: put the inbox away, the scenario starts in the evening
Q clock 2026-10-16T17:30

echo "1 evening: the thought on slide 7"
Q open decks/q3-board-review.pptx#slide 7; sleep 1.5
Q thought 'review conflict between this and [[q3-model.xlsx]] before friday'; sleep 5.5
check "saved" "thoughts: saved" "uid=t"
check "understood" "thoughts: understood" "kind=intent action=review-conflict"
grep -E '"intent"' $SIDECAR | tail -1
grep -c '(slide 7) review conflict' $SIDECAR | sed 's/^/anchored on slide 7: /'
shot rail-thought

echo "2 night: 02:00, the night shift"
Q clock 2026-10-17T02:00
Q nightshift plan; sleep 1; last "nightshift: plan job" 2
Q nightshift now; sleep 8
last "nightshift:" 6
# The fixture vault has other review-conflict thoughts (legal/supplier-agreement.pdf) the canned reply cannot
# honestly answer; the validator rejects it there, which is right. Only this thought's job must succeed.
UID_MINE=$(last "thoughts: saved" 1 | sed -E 's/.*uid=([a-z0-9]+).*/\1/')
check "job finished" "nightshift: finished job=${UID_MINE}:review-conflict" "memo=work/2026-10-17/"
check "job replied" "nightshift: replied job=${UID_MINE}:review-conflict" "replied"
MEMO=$(ls $VAULT/.flamingo/work/2026-10-17/*.md 2>/dev/null | head -1)
echo "memo: ${MEMO:-none}"
if [[ -n $MEMO ]]; then
  grep -q 'verdict: conflict' $MEMO && echo "ok   verdict conflict" || { echo "FAIL verdict"; FAILED=1; }
  grep -q 'Where they disagree' $MEMO && echo "ok   where they disagree" || { echo "FAIL disagree"; FAILED=1; }
  grep -E '\$249' $MEMO | grep -q '229' && echo "ok   row cites \$249 and 229" || { echo "FAIL row"; FAILED=1; }
  grep -q 'slide 7' $MEMO && grep -q 'Assumptions' $MEMO && echo "ok   slide 7 and Assumptions cited" || { echo "FAIL cites"; FAILED=1; }
  sed -n 1,40p $MEMO
else FAILED=1; fi
grep -c '"work"' $SIDECAR | sed 's/^/AI replies with work: /'
Q open decks/q3-board-review.pptx#slide 7; sleep 1.5
shot rail-memo-reply

echo "3 morning: 08:30, first open of the day"
Q clock 2026-10-17T08:30
Q briefing reset
Q briefing zoom; sleep 4
Q briefing status; last "briefing status" 1
check "inbox has the memo" "qa: briefing memos" "memos="
shot inbox
Q briefing select 1; Q briefing key return; sleep 1.2
shot memo-reader
Q briefing key esc; sleep 0.5; Q briefing close

echo "lag:"; grep "worst lag" $LOG | tail -2
quit
(( FAILED )) && echo "HEADLINE: FAIL" || echo "HEADLINE: ok"
echo "log: $LOG"
