#!/bin/zsh
# Seeds a scratch copy of fixtures/vault so the morning inbox has real content: dated thoughts
# (overdue, due today, a question, a to do, an idea whose file changed), three work memos in the
# night shift's format, a loose capture in _inbox and yesterday's session in the trail.
# Usage: scripts/briefing-seed.sh <vault>      Never run it on a real vault.
set -eu
V=${1:?vault}
TODAY=$(date +%F); Y=$(date -v-1d +%F); D2=$(date -v-2d +%F); D3=$(date -v-3d +%F); D5=$(date -v-5d +%F)
NOTES=$V/.flamingo/notes
mkdir -p $NOTES/_inbox $V/.flamingo/work/$TODAY

# add <path> <anchor|-> <date time> <text> <meta-json>
add() {
  local f=$NOTES/$1.md
  if [[ ! -f $f ]]; then
    mkdir -p $(dirname $f)
    printf -- '---\ntarget: %s\nid: %s\n---\n' $1 $(uuidgen) > $f
  fi
  local a=""; [[ $2 != "-" ]] && a="($2) "
  printf -- '- [%s] %s%s\n  <!-- flamingo: %s -->\n' "$3" "$a" "$4" "$5" >> $f
}

add finance/q3-model.xlsx "cell Revenue!C12" "$D3 16:20" 'Update the Arc price to $249 and re-run the margin view' \
  '{"due":"'$D2'","kind":"todo","kindBy":"user","origin":"human","uid":"t4k9w2m7ab"}'
add finance/unit-economics.xlsx "cell Margin!B4" "$Y 18:05" 'Send the revised unit economics to Priya before the 4pm sync' \
  '{"due":"'$TODAY'","kind":"todo","kindBy":"user","origin":"human","uid":"t6r1c8n3de"}'
add docs/pricing-memo.docx "page 3" "$D5 11:40" 'Why did the annual tier go? Check what Maya said in the interview, and summarize what we decided in [[pricing-decisions.md]]' \
  '{"kind":"intent","kindBy":"model","origin":"human","uid":"t3p7d2h5mv"}'
add tools/forecast.py - "$D3 09:12" 'Replace the hard coded waitlist number with the live count' \
  '{"kind":"todo","kindBy":"user","origin":"human","uid":"t9x5j1q4fg"}'
add design/moodboard.jpg - "$D5 15:30" 'Could the teaser open on the lamp arc instead of the product shot?' \
  '{"kind":"idea","kindBy":"user","origin":"human","uid":"t2h8v6s0kl"}'
add decks/q3-board-review.pptx "slide 7" "$Y 17:40" 'Review the conflict between this and [[q3-model.xlsx]] before Friday, the deck says $249' \
  '{"intent":{"action":"review-conflict","at":"'$Y' 17:41","confidence":0.92,"model":"gemma3:4b","objects":["decks/q3-board-review.pptx#slide 7","finance/q3-model.xlsx"]},"kind":"intent","kindBy":"model","origin":"human","uid":"t8m2k4q9xa"}'
add decks/q3-board-review.pptx "slide 7" "$TODAY 02:14" 'Conflict. Slide 7 prices Arc at $249; the model still multiplies by $229.
  Sources: [[q3-model.xlsx#cell Revenue!C12]]' \
  '{"model":"qwen3.8-27b","origin":"ai","parent":"t8m2k4q9xa","reason":"review-conflict","uid":"t2c7w5n1pd","work":"work/'$TODAY'/arc-price-deck-249-model-229.md"}'
add legal/supplier-agreement.pdf "page 4" "$D2 10:15" 'Does the 90-day exit clause survive the new supplier? Ask legal.' \
  '{"kind":"question","kindBy":"user","origin":"human","uid":"t5b3z7u2wq"}'
add research/market-sizing.pdf "page 12" "$D3 13:00" 'Check the TAM number against the Gartner figure, then compare it with [[unit-economics.xlsx]]' \
  '{"kind":"intent","kindBy":"model","origin":"human","uid":"t7y4n9e1rt"}'
add notes/open-questions.md - "$Y 08:30" 'Who owns the Q4 launch checklist now that Sam is out?' \
  '{"kind":"question","kindBy":"user","origin":"human","uid":"t1d6g3o8zx"}'

# A loose capture from another app.
printf -- '---\ntarget: _inbox/%s\nid: %s\n---\n- [%s 07:52] Call Rosa back about the packaging samples\n  <!-- flamingo: {"origin":"human","provenance":{"appName":"Messages"},"uid":"t0q2m5k8hp"} -->\n' \
  $TODAY $(uuidgen) $TODAY > $NOTES/_inbox/$TODAY.md

# The moodboard changed after the thought about it.
touch $V/design/moodboard.jpg

# Memos
cat > $V/.flamingo/work/$TODAY/arc-price-deck-249-model-229.md <<MEMO
---
flamingo: memo
thought: t8m2k4q9xa
on: "decks/q3-board-review.pptx#slide 7"
recipe: review-conflict
verdict: conflict
sources:
  - "decks/q3-board-review.pptx#slide 7 · $Y 15:02"
  - "finance/q3-model.xlsx#cell Revenue!C12 · $D2 11:48"
  - "docs/pricing-memo.docx#page 3 · $D5 11:00"
model: qwen3.8-27b
provider: llama
tokens: 7412
created: $TODAY 02:14
---
# Arc price: deck says \$249, model says \$229

Slide 7 prices Arc at \$249, but the revenue line in the model still multiplies by \$229, so the board would see a margin the deck cannot support.

## Where they disagree

- The deck, [[q3-board-review.pptx#slide 7]], shows \$249 and a 41% gross margin.
- The model, [[q3-model.xlsx#cell Revenue!C12]], uses \$229 and lands at 38%.
- The pricing memo, [[pricing-memo.docx#page 3]], settles on \$249 from the first of October.

## Next

Change the price cell, re-run the margin view, and check slide 9 which quotes the same number.
MEMO
cat > $V/.flamingo/work/$TODAY/annual-tier-support-cost.md <<MEMO
---
flamingo: memo
thought: t3p7d2h5mv
on: "docs/pricing-memo.docx#page 3"
recipe: summarize
sources:
  - "docs/pricing-memo.docx#page 3 · $D5 11:00"
  - "notes/pricing-decisions.md · $D3 17:20"
  - "research/interview-maya-chen.m4a#time 12:40 · $D5 09:00"
model: qwen3.8-27b
provider: llama
tokens: 5120
created: $TODAY 02:31
---
# The annual tier went for support cost, not demand

Maya says customers asked for it, but support for a yearly plan cost more than the discount earned, and [[pricing-decisions.md]] records the call as final.

## What was decided

- Drop the annual plan at launch and revisit after 500 orders.
- Keep the 30-day refund as the only commitment device.
MEMO
cat > $V/.flamingo/work/$TODAY/tam-three-readings.md <<MEMO
---
flamingo: memo
thought: t7y4n9e1rt
on: "research/market-sizing.pdf#page 12"
recipe: find-related
verdict: unclear
sources:
  - "research/market-sizing.pdf#page 12 · $D5 10:10"
  - "finance/unit-economics.xlsx · $D3 12:30"
  - "decks/arc-launch-plan.pptx#slide 4 · $D3 09:36"
model: qwen3.8-27b
provider: llama
tokens: 6033
created: $TODAY 02:52
---
# Three files read the market size three ways

The market-sizing report puts the addressable market at 1.4 million units, the launch plan quotes 1.1 million, and the unit economics sheet assumes 900 thousand.

## Worth reconciling

- [[market-sizing.pdf#page 12]] counts every household with a desk lamp.
- [[arc-launch-plan.pptx#slide 4]] counts only the three launch countries.
MEMO

# Yesterday evening in the trail, so the page has somewhere to resume.
iso() { date -u -r $(date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s) +%Y-%m-%dT%H:%M:%S.000Z; }
{
  for e in "17:40:00|decks/q3-board-review.pptx|slide 7" "17:52:00|finance/q3-model.xlsx|" "18:05:00|docs/pricing-memo.docx|page 3" "18:20:00|research/market-sizing.pdf|page 12" "18:31:00|design/arc-render.png|"; do
    t=${e%%|*}; rest=${e#*|}; f=${rest%%|*}; a=${rest#*|}
    if [[ -n $a ]]; then printf '{"anchor":"%s","at":"%s","file":"%s","kind":"opened"}\n' "$a" "$(iso "$Y $t")" "$f"
    else printf '{"at":"%s","file":"%s","kind":"opened"}\n' "$(iso "$Y $t")" "$f"; fi
  done
} >> $V/.flamingo/trail.jsonl
echo "seeded $V"
