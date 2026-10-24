# Flamingo plan 20: Capybara on another Mac

## What Lamont asked for (2026-10-24)

Capybara (tasks, on the home iMac) and Flamingo (files and thoughts, on the MacBook Pro)
connect over the home network and work as a pair:

1. A Capybara task can point at a Flamingo folder, picked as fast as typing.
2. A Flamingo thought can be sent to Capybara, where it waits as a card until accepted or rejected.
3. Both icons change frame by frame while they connect: the flamingo flies over and lands on the
   capybara's back, in the Dock and in both windows, and the connection counts as made at the
   moment it lands.
4. Everything between the Macs is encrypted. Thoughts may leave this Mac for this (CONTRACT.md).

## Decisions

- **Flamingo listens, Capybara connects.** Flamingo announces `_capyflamingo._tcp` on Bonjour
  with only a random-looking id (its key's fingerprint), its app name and the protocol version.
- **Pairing is numeric comparison.** Public keys and nonces in the clear, a commitment from the
  responder before it sees the initiator's nonce, six digits from all four, confirmed by a person
  on each Mac. Keys: X25519, made on each Mac, private half in the Keychain
  (`com.flamingo.app.link`).
- **Every connection is Noise KK** (X25519, ChaCha20-Poly1305, SHA-256): mutual authentication
  against the paired key and fresh keys per connection. A counter nonce rejects replays.
- **References, not replication.** Capybara keeps a copy of the folder list only (paths; deltas
  from FSEvents), never files or thoughts. Folders get the `com.flamingo.id` xattr when a task
  first points at them, so renames and moves are followed.
- **Exactly once.** Thoughts sent, decisions and done-states wait in an outbox (`link.json`) until
  the other Mac acknowledges them, across restarts; the receiver remembers ids it has handled.
- **The story drives the state.** Capybara picks the touchdown moment in its clock and sends it
  with the clock offset measured in the handshake; both Macs switch to connected at that instant.
- **One source.** Capybara's `Sources/CapybaraLink` is the original; `Sources/FlamingoLink/Shared`
  is a copy (Capybara's `scripts/sync-link.sh`). AppKit only, so it builds with the Command Line
  Tools; `flamingo-link-peer` runs Flamingo's side headless for tests.

## Where things are

| | |
|---|---|
| `Sources/FlamingoLink/CapybaraLink.swift` | requests (folder list, peek, open, pin, resolve), thoughts sent, decisions |
| `Sources/FlamingoLink/FolderCatalog.swift` | the folder list and its FSEvents deltas |
| `Sources/FlamingoLink/CapybaraPanel.swift` | the pairing and status panel, title-bar mark, Flamingo ▸ Capybara… |
| `Sources/Flamingo/CapybaraGlue.swift` | wiring to the shell, Send to Capybara |
| `Sources/FlamingoCapture/CommentsRail.swift` | `onSendToCapybara`, the menu item |

## Not yet

- Capybara tasks that point at a folder arrive here (`CapybaraLink.tasks(in:)`) but no view
  shows them yet; the Related rail is the place.
- The app glue (CapybaraGlue, the rail menu item) was written on the iMac, which has no Xcode;
  build on the MacBook before relying on it.
