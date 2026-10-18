#!/bin/zsh
# Run tests. Pass --filter <TargetName> to scope.
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
# A placeholder key keeps tests away from the Keychain, whose prompt would hang the run.
export ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-qa-placeholder}
# grep exits 1 when it prints nothing; `|| true` keeps that from failing a good run
# (swift's own status still comes through pipefail). --line-buffered shows progress live.
swift test "$@" 2>&1 | { grep --line-buffered -vE "Could not read priors" || true; }
