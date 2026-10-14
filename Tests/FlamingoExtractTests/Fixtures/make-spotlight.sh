#!/bin/zsh
# Rebuilds the Spotlight fixtures: formats no native extractor handles, written by textutil.
# legacy.doc goes through Office.mdimporter, notes.odt through RichText.mdimporter.
set -euo pipefail
cd "${0:A:h}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/legacy.txt" <<'TXT'
Pink plumage comes from carotenoids in brine shrimp.
Café naïve résumé — 日本語 “quoted” 🦩
Last line has "double quotes" and a back\slash.
TXT
textutil -convert doc -title "Flamingo Field Notes" -author "Ada Lovelace" \
  -subject "Migration survey" "$tmp/legacy.txt" -output legacy.doc

print 'Les flamants roses filtrent la vase.\nフラミンゴは片足で立つ。' > "$tmp/notes.txt"
textutil -convert odt -title "Flamant rose — フラミンゴ" -author "Zoë Ångström" "$tmp/notes.txt" -output notes.odt
