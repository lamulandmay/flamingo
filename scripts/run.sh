#!/bin/zsh
# Build and launch Flamingo as a real .app bundle so Quick Look, menus and
# Accessibility prompts behave. Plan 10 owns; everyone may use.
# Usage: run.sh [debug|release] [app arguments…]   e.g. run.sh -lastVault ~/Documents
set -e -o pipefail
cd "$(dirname "$0")/.."
CONFIG=debug
if [[ "$1" == debug || "$1" == release ]]; then CONFIG=$1; shift; fi
scripts/bundle.sh $CONFIG
# A copy running from this bundle would just be brought forward with the old binary, so
# replace it. Only this bundle: other sessions' test builds live elsewhere and keep running.
EXE="$PWD/build/Flamingo.app/Contents/MacOS/Flamingo"
if pgrep -f "^$EXE" >/dev/null; then
  pkill -f "^$EXE" || true
  for _ in {1..50}; do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done
fi
# -n: launch this bundle even if another build with the same bundle id is running.
if (( $# )); then open -n build/Flamingo.app --args "$@"; else open -n build/Flamingo.app; fi
