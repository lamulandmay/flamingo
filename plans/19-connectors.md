# Flamingo plan 19: connectors, a pasted link and a sentence become a purpose

## Context

The user is a student (ManageBac, so likely IB), a coder and a maker. The pains, in their words:
not knowing what to do next, a big task turning into TikTok, losing deadlines, too many apps.
Accounts: Outlook, Apple Mail, Apple Calendar.

What the user asked for:
1. A modular connector: paste a link, describe it in a sentence, and Claude turns that into a
   purpose. No auto-delivery: the earlier "Pilot" idea of pushing things at the person was cut.
2. Mail later: credentials for a mailbox and a local model watching it for things that need a
   reply.
3. Connector deadlines feed the morning briefing (`AttentionRanker`) next to thoughts.

## Decisions

- **App-wide, not per vault.** A school calendar is the person's, not a folder's. Cards live in
  `~/Library/Application Support/Flamingo/Connectors`; any other bundle, the CLI or a test run
  gets `Connectors-<bundle or process>` beside it (`ConnectorStore.defaultRoot`), so nothing but
  the installed app can touch the real ones.
- **What a connector brings in stays on this Mac, like thoughts.** Claude sees only the person's
  description, the link's host and the feed's shape (`FeedShape`: counts, standard property
  names, the span of dates). Never a title, a description, a UID, a place or a person.
- **A card is config, never code.** It names an adapter that lives in this module; a model can
  only fill fields, and every number it writes is clamped.
- **Items are not thoughts.** They never go into a sidecar, are never sent to Claude, and don't
  appear in the graph. The briefing ranks them beside thoughts.
- **The feed address is a secret.** The full link (its path carries the token) goes to the
  Keychain (service `com.flamingo.connector`, account = card id) or `FLAMINGO_CONNECTOR_<ID>` in
  the environment. The card keeps `https://host` only. Errors never carry the address.
- **Only the app touches the Keychain.** A test run or a QA copy would raise the access prompt;
  they use the environment.

## The purpose card

`<root>/<id>.json`, written by Claude from the description (`CardDrafting`), by a heuristic when
there is no key, or by the person:

```json
{
  "id": "managebac",
  "name": "ManageBac",
  "adapter": "ical",
  "source": "https://school.managebac.com",
  "described": "my school's ManageBac calendar, I only care about exams and essays",
  "purpose": "Exams and essays due",
  "role": "deadlines",
  "refreshMinutes": 60,
  "window": { "daysBack": 1, "daysAhead": 60 },
  "include": ["exam", "essay"],
  "exclude": ["mock"],
  "weight": 1.5,
  "createdBy": "claude",
  "enabled": true
}
```

| Field | Rule |
|---|---|
| `id` | Lowercase letters, digits, single dashes, at most 48, no leading or trailing dash. The name's slug; `-2`, `-3`… when taken (`freshID`). |
| `name` | At most 64 characters, trimmed. |
| `adapter` | `ical`, `eventkit`, `imap`, `json`. |
| `source` | What may be shown: the host for a feed, a selection for EventKit (`events: School, Family`). Never a token. |
| `described` | The person's words, verbatim. |
| `role` | `deadlines` (events become due at their start), `schedule`, `inbox`, `reference`. |
| `refreshMinutes` | 5 to 1,440. |
| `window` | `daysBack` 0 to 30, `daysAhead` 1 to 366, whole local days around today. |
| `include` / `exclude` | At most 20 each. Whole words or phrases, ignoring case and accents, a plural `s`/`es` allowed: `exam` matches "Exams", not "example"; `art` doesn't match "start". Exclude wins; a non-empty include needs one match. Titles and categories both count. |
| `weight` | 0 to 2, 1 is normal; anything not a number is 1. |
| `createdBy` | `claude`, `local`, `person`. |
| unknown keys | Kept and written back, so a newer card survives an older app. |

## Adapters

| Adapter | Reads | Status |
|---|---|---|
| `ical` | An iCalendar feed over https (`webcal://` accepted). VEVENT and VTODO; RRULE (daily, weekly, monthly, yearly with INTERVAL, COUNT, UNTIL, WKST, BYDAY, BYMONTHDAY, BYMONTH), EXDATE, RECURRENCE-ID overrides, DURATION, TZID including Windows zone names. Conditional GET (ETag, Last-Modified), 20 MB cap. | Phase 1, done |
| `eventkit` | Apple Calendar events and incomplete Reminders, optionally by calendar or list title. Access asked once when the card is added; a refresh never asks. | Phase 1b, done (not wired) |
| `imap` | A mailbox: unread mail from the window, a local model marks what needs a reply. | Phase 3 |
| `json` | A JSON feed with a mapping in the card. | Phase 4 |

## Items

`<root>/items/<id>.json`, state in `<root>/state/<id>.json` (version tag, last attempt, last
error, transient failures in a row).

| Field | |
|---|---|
| `id` | The UID; `uid@<occurrence epoch>` for a repeating entry or a reused UID (an override keeps the epoch of the slot it replaces); a stable hash of title and time without a UID; `#2` on exact duplicates. |
| `connector` | The card's id. |
| `kind` | `deadline`, `event`, `message`. |
| `title`, `categories`, `link`, `summary` | From the feed; the summary is cut at 1,000 characters. |
| `start`, `end`, `due`, `allDay` | A deadline has `due`; an event `start` and `end`. |
| `needsReply` | Mail only. |
| `fetchedAt` | A newer fetch alone is not a change. |

Refresh rules (`ConnectorSync`): a card is due after `refreshMinutes`; a transient failure
(offline, 408, 429, 5xx, a full disk) retries after 2, 4, 8… minutes up to the interval; any other
failure waits the interval. A failure keeps the old items. "Not modified" still re-filters stored
items, so past ones leave. A missing secret fails as "Feed address missing" without fetching.
`refreshStale` runs up to four feeds at once. `allItems` shows the same title at the same time
once across connectors, the deadline over the event.

## Phases

1. **iCal.** Module `FlamingoConnectors`: card, store, secrets, iCalendar parser, recurrence,
   adapter, sync, card drafting. Tests with a fake transport; no network, no Keychain, no real
   Application Support.
1b. **EventKit.** Calendar and Reminders through the same card, `NSCalendarsFullAccessUsageDescription`
   and `NSRemindersFullAccessUsageDescription` in `Info.plist`.
2. **App wiring and briefing.** A Connectors pane in Settings (⌘,): paste a link, describe it, see
   the drafted card, edit, save; the secret goes to the Keychain there. Refresh on launch, on wake
   and on a timer through `refreshStale`. `AttentionRanker` scores connector deadlines beside
   thoughts (`Due` from `due`, times the card's weight); the briefing lists them. Claude drafts
   the card only when there is an API key; otherwise the heuristic.
3. **Mail (IMAP, Outlook).** App-specific password for iCloud; OAuth for Outlook. Message bodies
   are read only by a local model (`LocalEndpoint`), never Claude, which sets `needsReply` and a
   one-line summary.
4. **More adapters.** JSON feeds, then whatever the person pastes that isn't iCal.

## Out of scope

- Writing back: no marking done in ManageBac, no replies sent.
- Push or auto-delivery of anything.
- Connector items in the graph, in search results or in sidecars.
- Claude seeing any item, title or mail.
- Per-vault connectors.
- Sync between Macs.

## Status (2026-10-18)

- Branch `feature/connectors`, not committed. `Package.swift` has `FlamingoConnectors` and
  `FlamingoConnectorsTests` (line in `plans/REQUESTS.md`).
- Phase 1 and 1b sources compile. Audit section 16 fixes are in: backoff on transient failure,
  re-filter on 304, whole-word include and exclude, `missingSecret`, injectable store root,
  RRULE/EXDATE/RECURRENCE-ID/DURATION, Windows zones, concurrent `refreshStale`, cross-connector
  de-dup, slug without a trailing dash.
- Tests in `Tests/FlamingoConnectorsTests/`: iCalendar, adapter, recurrence, store, secrets, sync
  (fake transport, test clock), purpose card, card drafting (the shape holds no titles). They
  type-check; not run yet.
- Next: run them, then phase 2.
