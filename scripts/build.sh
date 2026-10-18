#!/bin/zsh
# Build everything. Keep this green at all times.
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
# grep exits 1 when it prints nothing; `|| true` keeps that from failing a good build
# (swift's own status still comes through pipefail). --line-buffered shows progress live.
swift build "$@" 2>&1 | { grep --line-buffered -vE "Could not read priors" || true; }
