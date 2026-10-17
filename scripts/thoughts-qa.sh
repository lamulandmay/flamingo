#!/bin/zsh
# Headless QA for thoughts v2 in the shell (plan 16 M3, M4, M6). Runs a copy of build/Flamingo.app on a
# copy of fixtures/vault under its own bundle id (com.flamingo.qa-thoughts) with the fake local model
# (FLAMINGO_FAKE_LLM=1), drives it with build/qa-post and saves screenshots.
# Usage: scripts/thoughts-qa.sh <scratch-dir> [dark|light]
# Needs `scripts/bundle.sh debug` first. Only the copy's own pid is ever killed.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
SCR=${1:?scratch dir}; LOOK=${2:-dark}
mkdir -p build $SCR
[[ build/window-id -nt scripts/window-id.swift ]] || swiftc -O -o build/window-id scripts/window-id.swift
[[ build/qa-post -nt scripts/qa-post.swift ]] || swiftc -O -o build/qa-post scripts/qa-post.swift
APP=$SCR/FlamingoQA.app VAULT=$SCR/vault-$LOOK LOG=$SCR/qa-$LOOK.log
BUNDLE_ID=com.flamingo.qa-thoughts
CH=qa.thoughts.$$
rm -rf $APP $VAULT
cp -R build/Flamingo.app $APP; cp -R fixtures/vault $VAULT
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1
: > $LOG

PID=""
launch() {
  FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH FLAMINGO_FAKE_LLM=1 FLAMINGO_FAKE_LLM_DIR=$ROOT/fixtures/fake-llm FLAMINGO_QA_STREAM_DELAY=${STREAM:-0.18} \
    $APP/Contents/MacOS/Flamingo -lastVault $VAULT -FlamingoAppearance $LOOK >> $LOG 2>&1 &
  PID=$!; sleep 5
}
quit() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; }
trap 'kill $PID 2>/dev/null' EXIT
Q() { build/qa-post $CH "$*"; sleep ${W:-0.8}; }
shot() { screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$LOOK-$1.png; }
last() { grep "$1" $LOG | tail -${2:-1}; }
check() { if last "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1: wanted /$3/ in:"; last "$2" 2; fi }
SIDECAR="$VAULT/.flamingo/notes/decks/q3-board-review.pptx.md"

# The first catch-up after a launch holds the index; a thought saved meanwhile is indexed after it.
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
Q open decks/q3-board-review.pptx; sleep 1.5

echo "1 thought: uid at once, kind and action within 5 s"
Q thought 'review conflict between this and [[q3-model.xlsx]] before friday'; sleep 5.5
check "saved" "thoughts: saved" "uid=t"
check "understood" "thoughts: understood" "kind=intent action=review-conflict"
grep -E '"uid"|"kind"|"action"' $SIDECAR | head -3
shot rail-intent

echo "2 reply"
Q reply 'Fixed in the model'; sleep 1.5
shot thread

echo "3 @ai: pending row mid-stream, then the AI reply"
Q ai 'what price does the model use?'; sleep 1.6
shot ai-streaming; sleep 5
check "ai" "ai: answer" "uid=t"
shot ai-answer

echo "4 night shift at 02:00"
Q clock 2026-10-17T02:00
Q nightshift plan; sleep 1; last "nightshift: plan" 3
Q nightshift now; sleep 6
last "nightshift:" 8
ls $VAULT/.flamingo/work/*/ 2>/dev/null
Q open design/arc-lamp.usdz; sleep 2
echo "memo replies on arc-lamp: $(grep -c '"work"' $VAULT/.flamingo/notes/design/arc-lamp.usdz.md)"
shot memo-reply

echo "5 palette with a thought query"
Q key 40 cmd; sleep 0.5; Q type 'price'; sleep 2.5; shot palette
Q key 53; sleep 0.5

echo "lag:"; grep "worst lag" $LOG | tail -2
quit
echo "log: $LOG"
