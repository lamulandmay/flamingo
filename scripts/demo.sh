#!/bin/zsh
# Copy the fixture vault somewhere disposable and launch Flamingo on it.
# The copy is fresh every time; the fixture itself is never touched.
# FLAMINGO_DEMO_DIR overrides where the copy goes. Extra arguments go to the app as
# UserDefaults, e.g. `demo.sh -FlamingoAppearance dark` (once plan 01 reads that key).
set -e -o pipefail
cd "$(dirname "$0")/.."
BASE=${FLAMINGO_DEMO_DIR:-${TMPDIR:-/tmp}/flamingo-demo}
DEST="${BASE%/}/Kestrel Works"
rm -rf "$DEST"
mkdir -p "$BASE"
cp -R fixtures/vault "$DEST"
# Move the trail and comment dates so the latest session is today, and stamp file ids.
python3 scripts/prepare-demo.py "$DEST"
echo "$DEST"
# -lastVault lands in UserDefaults' argument domain for this launch only, so the
# user's own saved vault is left alone.
scripts/run.sh -lastVault "$DEST" "$@"
