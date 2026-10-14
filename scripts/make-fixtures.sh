#!/bin/zsh
# Regenerate fixtures/vault from fixtures/generate. Needs uv, ffmpeg, and macOS `say`.
# ONLY=office,images,media,state limits what gets rebuilt (text and sidecars always are).
set -e -o pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
VAULT=${1:-fixtures/vault}
mkdir -p "$VAULT/design"
if [[ -z "$ONLY" || "$ONLY" == *model* ]]; then
  swift fixtures/generate/make_lamp.swift "$VAULT/design/arc-lamp.usdz"
  echo "  design/arc-lamp.usdz"
fi
cd fixtures/generate
uv run --quiet --python 3.12 --with python-pptx --with python-docx --with openpyxl --with reportlab --with pillow \
  python make_vault.py "../../$VAULT"
