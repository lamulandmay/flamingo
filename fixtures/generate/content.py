"""Words for the demo vault. Kestrel Works, twelve people, one desk lamp called Arc.

The pricing story runs through everything on purpose: the board deck says $249, the
model still says $229, the memo argues $279, the whiteboard floats a $329 Pro tier, and
a customer named $260 unprompted. Comments and trails connect them.
"""

COMPANY = "Kestrel Works"

BOARD_DECK = {
    "path": "decks/q3-board-review.pptx",
    "title": "Q3 2026 Board Review",
    "subtitle": "Kestrel Works  ·  October 9, 2026",
    "slides": [
        ("Agenda", [
            "Q3 results",
            "Arc: production readiness and customer research",
            "Pricing and unit economics",
            "Supply chain and hiring",
            "Risks and asks",
        ], None),
        ("Q3 at a glance", [
            "Revenue $412k, up 38% quarter over quarter",
            "Gross margin 52%, up from 47%",
            "Cash $2.1M; runway 19 months at current burn",
            "Waitlist for Arc: 4,812 as of September 30",
        ], "Runway drops to 14 months if we draw the inventory facility. Say both numbers."),
        ("Revenue by channel", "CHART", "DTC carried the quarter. Retail is two accounts, both renewing."),
        ("Arc: production readiness", [
            "EVT complete in July",
            "DVT passed 14 of 16 tests; hinge torque and driver EMI being reworked",
            "PVT starts October 27 at Dongguan line 3",
            "Tooling for the shade is cut; base tooling ships October 20",
        ], None),
        ("Arc: what customers told us", [
            "22 interviews across architects, writers, and engineers",
            "Flicker at low brightness is the most cited complaint about current lamps",
            "Warm dimming below 2700K mattered to 15 of 22",
            "Clamp mounting asked for unprompted by 6",
        ], None),
        ("Pricing", [
            "Arc: $249",
            "Arc Mini: $179, January",
            "Launch November 18 with DTC first, retail in week two",
            "No launch discount; waitlist gets free shipping",
        ], "This is the number we want the board to anchor on."),
        ("Unit economics", "TABLE", None),
        ("Supply chain", [
            "LED modules from Lumen Optics, single source",
            "Ten-week lead time on modules; MOQ 5,000",
            "Second source qualified by end of Q1",
            "Freight: ocean for launch stock, air only for top-ups",
        ], None),
        ("Hiring", [
            "Firmware engineer: offer out",
            "Operations lead: final round",
            "Customer experience: opens November 1",
        ], None),
        ("Risks", [
            "Holiday shipping cutoff December 12",
            "Price perception against $150 lamps",
            "Single-source LED module",
        ], None),
        ("Asks of the board", [
            "Approve a $600k inventory facility",
            "Introductions to two retail buyers before November 4",
            "Feedback on Arc Pro as a 2027 line",
        ], None),
    ],
}

LAUNCH_DECK = {
    "path": "decks/arc-launch-plan.pptx",
    "title": "Arc Launch Plan",
    "subtitle": "November 18, 2026",
    "slides": [
        ("Goals", [
            "3,000 units in the launch window",
            "4.6 or better average rating at 60 days",
            "Returns under 3%",
        ], None),
        ("Timeline", [
            "October 27: PVT starts",
            "November 4: press embargo briefings",
            "November 18: launch",
            "December 12: last ship date for the holidays",
        ], None),
        ("Pre-launch", [
            "Waitlist: 4,812",
            "Seed 40 units with designers and writers",
            "Press kit: photography, spec sheet, founder note",
        ], None),
        ("Launch day", [
            "DTC only for the first week",
            "Retail partners in week two",
            "Founder livestream at 10:00 Pacific",
        ], None),
        ("Channels and pricing", [
            "DTC: $249",
            "Retail: $249 MAP",
            "B2B: $219 at 10 units or more",
        ], None),
        ("Messaging", [
            "Light that stays out of the way",
            "Flicker-free at every brightness",
            "Dims warm, like a filament",
        ], None),
        ("Content", [
            "Teaser film, 8 seconds, cut for vertical and wide",
            "Product photography in three rooms",
            "Two-minute setup video",
        ], None),
        ("Support readiness", [
            "FAQ and setup guide live on launch day",
            "Two-year warranty",
            "30-day returns, prepaid label",
        ], None),
        ("Open questions", [
            "Arc Mini at launch, or January?",
            "Is there an Arc Pro, and what makes it Pro?",
            "Clamp mount as an accessory or in the box?",
        ], None),
    ],
}

CHANNEL_REVENUE = [("DTC", 251), ("Retail", 111), ("B2B", 50)]  # $k, sums to 412

UNIT_ECON_ROWS = [
    ("", "Arc", "Arc Mini"),
    ("Price", "$249", "$179"),
    ("BOM", "$71.40", "$52.10"),
    ("Landed cost", "$84.10", "$62.30"),
    ("Payment and fulfillment", "$19.20", "$15.80"),
    ("Contribution", "$145.70", "$100.90"),
    ("Contribution margin", "58%", "56%"),
]

PRODUCT_BRIEF = {
    "path": "docs/arc-product-brief.docx",
    "title": "Arc — Product Brief",
    "sections": [
        ("Overview", [
            "Arc is a desk lamp for people who work at the same desk for eight hours. It throws "
            "an even, flicker-free pool of light across a 900 by 600 millimetre work surface and "
            "dims warm, from 4000K at full brightness down to 2200K at its lowest setting.",
            "It replaces the clip-on task lights and floor lamps our interviewees described as "
            "either too harsh or too dim, and it costs less than the architect lamps they admire "
            "but do not buy.",
        ]),
        ("Who it is for", [
            "Architects, writers, and engineers working from home or in small studios. They "
            "notice flicker, they care about colour, and they keep a tidy desk.",
        ]),
        ("Requirements", None),
        ("Light quality", [
            "CRI 95 or better across the dimming range.",
            "No visible flicker at any brightness; PWM above 20 kHz or constant-current dimming.",
            "Warm dimming curve that tracks a filament from 4000K to 2200K.",
        ]),
        ("Mechanics", [
            "Two-section arm with friction hinges; holds position with the shade at full reach.",
            "Shade diameter 140 mm, spun aluminium, matte interior.",
            "Cast zinc base, 1.6 kg, with a felt underside.",
        ]),
        ("Controls", [
            "A single touch strip on the shade rim: tap for on and off, slide to dim.",
            "Remembers the last brightness.",
        ]),
        ("Non-goals", [
            "App control or smart-home integration in version one.",
            "Clamp mounting.",
            "Battery operation.",
        ]),
        ("Open issues", [
            "Hinge torque drifts after 5,000 cycles in DVT; rework due October 17.",
            "Driver EMI fails the conducted-emissions limit at 150 kHz by 3 dB.",
        ]),
    ],
    "signoff": "Signed off by Priya Raman and Tom Okafor, September 28, 2026.",
}

PRICING_MEMO = {
    "path": "docs/pricing-memo.docx",
    "title": "Arc Pricing",
    "meta": [("To", "Priya Raman"), ("From", "Tom Okafor"), ("Date", "October 12, 2026")],
    "sections": [
        ("Recommendation", [
            "Launch Arc at $279 with a $249 waitlist price that expires on December 31. "
            "Keep Arc Mini at $179 and hold it until January.",
        ]),
        ("Background", [
            "The board deck anchors on $249. The Q3 model still uses $229 from the August plan. "
            "Neither number was tested against the interviews, where six of the last ten "
            "participants volunteered a number above $250 without being asked.",
        ]),
        ("Options", "TABLE"),
        ("Analysis", [
            "At $249 contribution margin is 58% and we need 3,000 units to clear the launch "
            "inventory. At $279 margin rises to 62% and 2,700 units cover the same contribution.",
            "The risk at $279 is the comparison with $150 lamps on retail shelves. The waitlist "
            "price gives the launch audience a reason to buy now without resetting the reference "
            "price for retail.",
        ]),
        ("Risks", [
            "Press coverage quotes the higher price.",
            "Retail partners ask for $249 MAP anyway.",
            "Arc Pro, if it exists, has less room above Arc.",
        ]),
        ("Decision needed by", [
            "October 20, so the price is in the press kit before the November 4 briefings.",
        ]),
    ],
    "options": [
        ("Option", "Price", "Margin", "Units to clear"),
        ("A — August plan", "$229", "55%", "3,400"),
        ("B — Board deck", "$249", "58%", "3,000"),
        ("C — Recommended", "$279", "62%", "2,700"),
    ],
}

SUPPLIER_AGREEMENT = {
    "path": "legal/supplier-agreement.pdf",
    "title": "LED Module Supply Agreement",
    "pages": [
        ("Parties", [
            "This agreement is made on September 15, 2026 between Kestrel Works, Inc. "
            "(\"Buyer\") and Lumen Optics Co., Ltd., Shenzhen (\"Supplier\").",
            "Supplier will manufacture and deliver the LED module described in Schedule A for "
            "use in the Buyer's Arc and Arc Mini desk lamps.",
            "The term is two years from the date above and renews for one-year periods unless "
            "either party gives ninety days' notice.",
        ]),
        ("Specification", [
            "Module LM-2240: 24 mid-power LEDs on a 40 mm aluminium-core board, tunable from "
            "2200K to 4000K, CRI 95 minimum (R9 above 60), binned to a three-step MacAdam ellipse.",
            "Supplier will provide LM-80 data and a certificate of conformance with each lot.",
            "Any change to LED bin, phosphor, or board material requires thirty days' written "
            "notice and Buyer approval.",
        ]),
        ("Pricing", "TABLE"),
        ("Lead times and delivery", [
            "Standard lead time is ten weeks from purchase order to ex-works.",
            "Buyer may place one expedite per quarter at a 12% premium with a six-week lead time.",
            "Delivery is FOB Shenzhen. Title and risk pass to Buyer at loading.",
            "Late delivery beyond fourteen days entitles Buyer to a 2% credit per week, capped at 10%.",
        ]),
    ],
    "pricing": [
        ("Quantity per order", "Unit price (USD)", "Notes"),
        ("5,000", "$14.20", "Minimum order quantity"),
        ("10,000", "$12.80", "Requires 12-month forecast"),
        ("25,000", "$11.60", "Requires 12-month forecast"),
    ],
}

MARKET_SIZING = {
    "path": "research/market-sizing.pdf",
    "title": "Desk Lighting Market Sizing",
    "pages": [
        ("Summary", [
            "We estimate a serviceable market of 3.1 million premium task lamps a year across "
            "the United States, United Kingdom, Germany, and Japan, worth roughly $620 million "
            "at an average price of $200.",
            "Arc needs one tenth of one percent of that in its first year.",
        ]),
        ("Method", "TABLE"),
        ("Caveats", [
            "Home office counts come from national surveys of differing years.",
            "The premium share is taken from one retailer's category data and may overstate the "
            "market outside design-led stores.",
        ]),
    ],
    "method": [
        ("Step", "United States", "Rest of markets", "Total"),
        ("Home offices", "38.0M", "41.5M", "79.5M"),
        ("Replace a lamp each year", "12%", "10%", "—"),
        ("Premium share (over $120)", "35%", "30%", "—"),
        ("Serviceable lamps per year", "1.6M", "1.5M", "3.1M"),
    ],
}

# Q3 model. Monthly rows Jan..Dec. Retail units in column C; Revenue!C12 is November.
MODEL_ASSUMPTIONS = [
    ("Assumption", "Value", "Note"),
    ("Launch date", "2026-11-18", "DTC first, retail week two"),
    ("Arc units, launch window", 3000, "Through December 31"),
    ("Arc ASP", 229, "From the August plan"),
    ("Arc Mini ASP", 179, "January"),
    ("Retail margin", 0.42, "Of retail price"),
    ("Returns rate", 0.03, ""),
    ("Payment fees", 0.029, "Plus $0.30 per order"),
    ("Monthly opex", 118000, "Excluding inventory"),
    ("Opening cash, Jul 1", 2480000, ""),
]

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
# Revenue from the pendant and sconce the studio already sells, $. Q3 sums to $412k, Q2 to $299k.
OTHER_REVENUE = [82000, 79000, 88000, 96000, 101000, 102000, 128000, 136000, 148000, 151000, 165000, 210000]
ARC_DTC = [0] * 10 + [1350, 1050]
ARC_RETAIL = [0] * 10 + [260, 340]

BOM = [
    ("Base, cast zinc", "Hengli Die Casting", 1, 9.60),
    ("Arm, aluminium extrusion", "Hengli Die Casting", 2, 2.35),
    ("Hinge assembly", "Precision Hinge Co.", 2, 3.10),
    ("Shade, spun aluminium", "Ningbo Metalcraft", 1, 7.80),
    ("Diffuser", "Clearform Plastics", 1, 1.45),
    ("Driver board", "Shenzhen Arcwave", 1, 8.90),
    ("Touch dimmer flex", "Shenzhen Arcwave", 1, 2.65),
    ("LED module LM-2240", "Lumen Optics", 1, 14.20),
    ("Power supply, 24V", "Meanwell", 1, 6.10),
    ("Cable and plug", "Dongguan Wire", 1, 2.20),
    ("Felt pad and fasteners", "Various", 1, 1.15),
    ("Packaging", "Kraftline Packaging", 1, 3.95),
    ("Assembly and test", "Dongguan line 3", 1, 2.50),
]  # totals 71.40 per unit; LED module lands in BOM!D9

FREIGHT_DUTY = 12.70  # landed = 84.10

PRICING_TIERS = [
    ("Tier", "Price", "Landed cost", "Fees and fulfillment", "Contribution", "Margin"),
    ("Arc Mini", 179, 62.30, 15.80),
    ("Arc", 249, 84.10, 19.20),
    ("Arc, option C", 279, 84.10, 20.70),
    ("Arc Pro (uncosted)", 329, None, None),
]

SCENARIO_PRICES = [229, 249, 279]
SCENARIO_UNITS = [2000, 2500, 2700, 3000, 3400, 4000]

MARKDOWN_NOTES = {
    "notes/launch-checklist.md": """# Launch checklist

- [x] Shade tooling cut
- [x] Teaser film locked — [[arc-teaser.mp4]]
- [ ] Base tooling ships (Oct 20)
- [ ] LED module PO placed — ten-week lead time, see [[supplier-agreement.pdf#page 4]]
- [ ] Price decided — [[pricing-decisions]]
- [ ] Press kit: photography, spec sheet, founder note
- [ ] Waitlist count refreshed in [[arc-launch-plan.pptx#slide 4]]
- [ ] FAQ and setup guide
- [ ] Retail partner onboarding for week two
- [ ] Holiday last-ship date on the site: December 12
""",
    "notes/pricing-decisions.md": """# Pricing decisions

Running log. Newest at the bottom.

## August plan
Arc at $229. Built into [[q3-model.xlsx]] before the interviews.

## Board review, October 9
Arc at $249 on [[q3-board-review.pptx#slide 7]]. Contribution 58%.
Nobody on the board pushed back.

## Memo, October 12
Tom recommends $279 with a $249 waitlist price. See [[pricing-memo.docx|the memo]] and the
scenarios in [[unit-economics.xlsx#sheet Scenarios]].

## Still open
- Is Arc Pro real? It is on the [[whiteboard-pricing.jpg]] and nowhere else.
- What did customers say? [[interview-maya-chen.m4a]] is the clearest one.
""",
    "notes/weekly-sync-2026-10-08.md": """# Weekly sync — October 8

Priya, Tom, Jun, Alma

## Board deck
- Final pass on [[q3-board-review.pptx]] tonight. Jun owns charts.
- Runway slide needs both numbers.

## Arc
- DVT: two failures, hinge torque and driver EMI. Both have owners.
- Brief is still the source of truth: [[arc-product-brief.docx]].
- Alma to send the render to the photographer once the shade is final — [[arc-render.png]] is DVT.

## Pricing
- Tom drafting a memo. Decisions go in [[pricing-decisions]].

## Next week
- PVT readiness review
- Supplier call with Lumen about the MOQ
""",
    "notes/open-questions.md": """# Open questions

- Does the shade in [[arc-lamp.usdz]] match the brief? Model says 150 mm.
- Is the serviceable market in [[market-sizing.pdf]] too generous outside design stores?
- Clamp mount: accessory or in the box? Six interviewees asked.
- Who signs off the [[launch-checklist]] before the press embargo?
""",
}

FORECAST_PY = '''"""Rough November–December forecast for Arc. Run: python3 forecast.py"""

LAUNCH_UNITS = 3000
DTC_SHARE = 0.80
RETAIL_MARGIN = 0.42
RETURNS = 0.03


def revenue(units: int, asp: float) -> float:
    dtc = units * DTC_SHARE * asp
    retail = units * (1 - DTC_SHARE) * asp * (1 - RETAIL_MARGIN)
    return (dtc + retail) * (1 - RETURNS)


def main() -> None:
    for units in (2000, 2500, 3000, 3500):
        # TODO: read ASP from the model instead of hardcoding it.
        asp = 229
        print(f"{units:>5} units  ${revenue(units, asp):>10,.0f}")


if __name__ == "__main__":
    main()
'''

# The interview. (speaker, line, tag). Tags pin sidecar anchors to real times.
INTERVIEW = [
    ("tom", "This is Tom from Kestrel Works, talking with Maya Chen. Thanks for doing this.", None),
    ("maya", "Happy to. I've been complaining about my desk lamp for about three years, so this is overdue.", None),
    ("tom", "What do you do, and where do you work?", None),
    ("maya", "I'm an architect. Most days I'm at home, at a big table by the window, drawing on paper and on a tablet.", None),
    ("tom", "What's wrong with the lamp you have now?", None),
    ("maya", "It flickers when I turn it down. You can't see it, exactly, but after an hour my eyes hurt. And the light is blue. Everything looks like an operating room.", None),
    ("tom", "If a lamp fixed both of those, what would you expect to pay?", None),
    ("maya", "Honestly? Up to two hundred and sixty dollars, if it really dims without flicker. Above that I'd start looking at the Italian ones.", "price"),
    ("tom", "That's helpful. Anything else that would make you choose one lamp over another?", None),
    ("maya", "How it attaches. My table is full. If I could clamp it to the edge instead of giving up a corner to the base, I'd buy it today.", "clamp"),
    ("tom", "So a clamp matters more than the base.", None),
    ("maya", "For me, yes. Every architect I know has the same table and the same problem.", None),
    ("tom", "Last question. Would you want to control it from your phone?", None),
    ("maya", "No. I want to touch the lamp, and I want it to remember where I left it.", None),
    ("tom", "Perfect. Thank you, Maya.", None),
]

# Sidecars. {anchor_tag} placeholders are filled from real media timings.
# (target, id, [(timestamp, anchor_kind, anchor_value, text)])
SIDECARS = [
    ("decks/q3-board-review.pptx", "3F2C9A0E-5B1D-4C7E-9A63-1E0B6D2F8C41", [
        ("2026-10-08 17:20", "slide", "3", "Runway is 19 months at current burn and 14 if we draw the facility. Say both."),
        ("2026-10-08 17:31", "slide", "11", "Risks are in the wrong order.\nSingle-source LED is the one that can actually stop us shipping. Put it first, and link the second-source plan."),
        ("2026-10-09 08:45", "slide", "12", "Name the two retail buyers before the meeting."),
        ("2026-10-13 14:11", "slide", "7", "Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229."),
    ]),
    ("decks/arc-launch-plan.pptx", "8A41D7C2-0F3E-4B95-A7D8-6C2E91B53F07", [
        ("2026-10-14 09:36", "slide", "4", "Waitlist number is from September 30. Pull the current count before the press kit goes out. [[launch-checklist]]"),
    ]),
    ("docs/arc-product-brief.docx", "C7E05B94-21AF-4D6B-8E3C-59F1A0D2B7E6", [
        ("2026-09-28 16:02", None, None, "Signed off. Changes from here go through Tom."),
        ("2026-10-14 09:48", "page", "2", "Move clamp mounting out of Non-goals. Six of 22 interviewees asked for it, including [[interview-maya-chen.m4a#time {clamp}]]."),
    ]),
    ("docs/pricing-memo.docx", "1D9B6E3A-7C42-4F80-B5A1-0E8D3C6F92B4", [
        ("2026-10-13 14:19", None, None, "Option B is what the board saw. If we go with C, [[q3-board-review.pptx#slide 7]] needs a footnote before it goes in the data room."),
    ]),
    ("finance/q3-model.xlsx", "5E8F2B71-9D06-4A3C-8B47-F2C1D06E9A35", [
        ("2026-10-13 14:44", "cell", "Revenue!C12", "November retail units assume retail ships in launch week. [[arc-launch-plan.pptx#slide 5]] says week two. Cut to 180."),
    ]),
    ("finance/unit-economics.xlsx", "B26A4F18-E3C7-4D59-9F02-7A8E5C1B3D60", [
        ("2026-10-13 14:31", "sheet", "Scenarios", "At $249 and 3,000 units contribution is $437k. At $279 we only need 2,700 for more than that. [[pricing-decisions]]"),
        ("2026-10-14 10:06", "cell", "BOM!D9", "Confirmed $14.20 per [[supplier-agreement.pdf#page 3]]. We are on the 5,000 tier until we commit to a forecast."),
    ]),
    ("legal/supplier-agreement.pdf", "E4C3A8D1-6B0F-4E27-A953-2D7F1B8C0E96", [
        ("2026-10-14 09:55", "page", "3", "MOQ 5,000 at $14.20. The $12.80 price needs a 12-month forecast we haven't given them. Check [[unit-economics.xlsx#cell BOM!D9]]."),
        ("2026-10-14 10:01", "page", "4", "Ten-week lead time means the PO has to go out by October 20 to make the December 12 last-ship date. [[launch-checklist]]"),
    ]),
    ("research/market-sizing.pdf", "7B0E9C25-4A18-4F63-8D2E-C5A9F3071B4D", [
        ("2026-10-07 11:02", "page", "2", "Home offices should be home offices with a dedicated desk, roughly half. Even halved we only need a rounding error of it. [[open-questions]]"),
    ]),
    ("design/whiteboard-pricing.jpg", "29D7F0A6-B5E1-4C38-9E74-0A6B2D8F5C13", [
        ("2026-10-13 14:23", None, None, "Arc Pro at $329 was never costed. Nothing in [[unit-economics.xlsx]] supports it."),
    ]),
    ("design/arc-render.png", "D05A1E7B-8C29-4F6D-B3A0-6E4F9C2D1B58", [
        ("2026-10-02 10:20", None, None, "This is the DVT shade, not final. Keep it out of [[arc-launch-plan.pptx#slide 8]] until PVT."),
    ]),
    ("design/moodboard.jpg", "6C8B3D02-F4A7-4E1B-8D95-3B0E7A2C6F19", [
        ("2026-10-02 10:15", None, None, "Bone and graphite at launch. Coral only on the packaging. [[arc-render.png]]"),
    ]),
    ("design/arc-lamp.usdz", "A9F1C6E3-2D58-4B07-9C4A-E81D5F3B7062", [
        ("2026-10-14 10:13", "node", "Shade", "Shade is 150 mm in the model and 140 mm in [[arc-product-brief.docx]]. Which one went to Ningbo?"),
    ]),
    ("media/arc-teaser.mp4", "F3B85D4C-0E72-4A19-B6D3-9C1E8A5F2D07", [
        ("2026-10-14 10:18", "time", "0:05", "Date card should say November 18, not just November. Matches [[arc-launch-plan.pptx#slide 3]]."),
    ]),
    ("research/interview-maya-chen.m4a", "40E6A9B3-C1D8-4F25-8A7E-2B5D0F9C6E14", [
        ("2026-10-14 09:41", "time", "{price}", "She would pay up to $260 if it dims without flicker. Supports option C in [[pricing-memo.docx]]."),
        ("2026-10-14 09:43", "time", "{clamp}", "Clamp matters more than the base for her. The brief lists it as a non-goal: [[arc-product-brief.docx]]"),
    ]),
    ("notes/pricing-decisions.md", "92A0D4F7-3E6B-4C81-B5F9-1D7C0A8E3B26", [
        ("2026-10-13 14:38", "line", "13", "This entry should cite [[interview-maya-chen.m4a#time {price}]]. She named $260 without being asked."),
    ]),
    ("tools/forecast.py", "0B7E3F59-A6C2-4D18-9B03-F8E1D5A4C27E", [
        ("2026-10-06 16:30", "line", "18", "Hardcodes the $229 ASP. Read it from [[q3-model.xlsx#sheet Assumptions]] instead."),
    ]),
]

# Two working sessions. (wall time, kind, file, anchor_kind, anchor_value, text)
# `commented` events are generated from SIDECARS when their timestamp falls inside a session.
TRAIL = [
    # Tuesday afternoon: the pricing contradiction.
    ("2026-10-13 14:05:10", "opened", "decks/q3-board-review.pptx", None, None, None),
    ("2026-10-13 14:07:42", "opened", "decks/q3-board-review.pptx", "slide", "7", None),
    ("2026-10-13 14:09:03", "opened", "finance/q3-model.xlsx", "sheet", "Assumptions", None),
    ("2026-10-13 14:11:30", "linked", "decks/q3-board-review.pptx", None, None, "q3-model.xlsx"),
    ("2026-10-13 14:14:05", "searched", None, None, None, "price"),
    ("2026-10-13 14:14:41", "opened", "docs/pricing-memo.docx", None, None, None),
    ("2026-10-13 14:19:40", "linked", "docs/pricing-memo.docx", None, None, "q3-board-review.pptx"),
    ("2026-10-13 14:21:12", "opened", "design/whiteboard-pricing.jpg", None, None, None),
    ("2026-10-13 14:26:00", "opened", "finance/unit-economics.xlsx", "sheet", "Scenarios", None),
    ("2026-10-13 14:34:22", "opened", "notes/pricing-decisions.md", None, None, None),
    ("2026-10-13 14:40:09", "opened", "finance/q3-model.xlsx", "cell", "Revenue!C12", None),
    ("2026-10-13 14:52:31", "opened", "decks/q3-board-review.pptx", "slide", "8", None),
    # Wednesday morning: launch readiness.
    ("2026-10-14 09:30:15", "opened", "decks/arc-launch-plan.pptx", None, None, None),
    ("2026-10-14 09:31:40", "opened", "decks/arc-launch-plan.pptx", "slide", "4", None),
    ("2026-10-14 09:38:28", "opened", "research/interview-maya-chen.m4a", None, None, None),
    ("2026-10-14 09:45:02", "opened", "docs/arc-product-brief.docx", None, None, None),
    ("2026-10-14 09:51:20", "searched", None, None, None, "lead time"),
    ("2026-10-14 09:51:48", "opened", "legal/supplier-agreement.pdf", "page", "3", None),
    ("2026-10-14 09:58:10", "opened", "legal/supplier-agreement.pdf", "page", "4", None),
    ("2026-10-14 10:03:01", "opened", "finance/unit-economics.xlsx", "cell", "BOM!D9", None),
    ("2026-10-14 10:10:33", "opened", "design/arc-lamp.usdz", None, None, None),
    ("2026-10-14 10:15:40", "opened", "media/arc-teaser.mp4", None, None, None),
    ("2026-10-14 10:20:11", "opened", "notes/launch-checklist.md", None, None, None),
    ("2026-10-14 10:22:47", "linked", "notes/launch-checklist.md", None, None, "supplier-agreement.pdf"),
]
TRAIL_SESSIONS = [("2026-10-13 14:00", "2026-10-13 15:15"), ("2026-10-14 09:25", "2026-10-14 10:30")]
FIXTURE_UTC_OFFSET_HOURS = 8
TRAIL_NAMES = {0: "Which price is real"}
