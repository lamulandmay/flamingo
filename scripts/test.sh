#!/bin/zsh
# Run tests. Pass --filter <TargetName> to scope.
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test "$@" 2>&1 | grep -vE "Could not read priors"
