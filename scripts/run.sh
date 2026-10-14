#!/bin/zsh
# Build and launch Flamingo as a real .app bundle so Quick Look, menus and
# Accessibility prompts behave. Plan 10 owns; everyone may use.
# Usage: run.sh [debug|release] [app arguments…]   e.g. run.sh --vault ~/Documents
set -e -o pipefail
cd "$(dirname "$0")/.."
CONFIG=debug
if [[ "$1" == debug || "$1" == release ]]; then CONFIG=$1; shift; fi
scripts/bundle.sh $CONFIG
# A running copy would just be brought forward with the old binary; replace it.
if pgrep -x Flamingo >/dev/null; then
  pkill -x Flamingo || true
  for _ in {1..50}; do pgrep -x Flamingo >/dev/null || break; sleep 0.1; done
fi
if (( $# )); then open build/Flamingo.app --args "$@"; else open build/Flamingo.app; fi
