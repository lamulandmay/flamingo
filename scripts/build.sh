#!/bin/zsh
# Build everything. Keep this green at all times.
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift build "$@" 2>&1 | grep -vE "Could not read priors" 
