import AppKit
import FlamingoCore
import FlamingoLink

// Flamingo's side of the link to Capybara, without Flamingo's window: for tests and for
// checking that two Macs can see each other.
//
//   flamingo-link-peer --vault DIR [--data DIR] [--name NAME] [--auto-pair] [--keychain]
//
// Prints one JSON line per event. Reads commands on stdin, one per line:
//   send <file relative to the vault> <uid> <text>     sends a thought to the paired Capybara
//   status                                              prints the link's state
//   quit

setbuf(stdout, nil)
let args = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func emit(_ o: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    print(String(decoding: data, as: UTF8.self))
}

guard let vaultPath = argument("--vault") else {
    print("usage: flamingo-link-peer --vault DIR [--data DIR] [--name NAME] [--auto-pair] [--keychain]")
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
    let data = URL(fileURLWithPath: argument("--data") ?? FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-link-peer").path)
    let link = CapybaraLink(name: argument("--name") ?? (Host.current().localizedName ?? "Flamingo"), directory: data,
                            keychainService: args.contains("--keychain") ? "com.flamingo.app.link" : nil)
    link.animator.animatesDock = false
    var lastPhase = ""
    var lastCode: String?
    link.onChange = {
        let s = link.node.primary
        let phase = s?.phase.rawValue ?? "unpaired"
        if phase != lastPhase { lastPhase = phase; emit(["event": "phase", "phase": phase, "peer": s?.peer.name ?? ""]) }
        if let p = link.node.pairing {
            if p.code != lastCode, let code = p.code {
                lastCode = code
                emit(["event": "pairing", "code": code, "peer": p.peerName])
                if args.contains("--auto-pair") { link.node.confirmPairing() }
            }
            if p.done { emit(["event": "paired", "peer": p.peerName]); link.node.cancelPairing(tell: false); lastCode = nil }
            if let f = p.failed { emit(["event": "pairing-failed", "why": f]); link.node.cancelPairing(tell: false); lastCode = nil }
        }
    }
    link.revealFolder = { path in emit(["event": "open-folder", "path": path]) }
    link.revealThought = { file, uid in emit(["event": "open-thought", "file": file.relativePath, "uid": uid]) }
    link.notify = { text in emit(["event": "notify", "text": text]) }
    link.applyThoughtState = { _, _, _ in false }
    link.setVault(Vault(root: URL(fileURLWithPath: vaultPath)))
    link.start()
    emit(["event": "started", "id": link.node.id, "name": link.node.name])

    // Commands from stdin, handled on the main queue.
    FileHandle.standardInput.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil; return }
        for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch parts.first {
                    case "send" where parts.count == 4:
                        let file = FileRef(relativePath: parts[1])
                        let text = parts[3].replacingOccurrences(of: "\\n", with: "\n")
                        let r = link.send(text: text, uid: parts[2], file: file, folder: file.directory, anchor: "page 2", due: nil)
                        emit(["event": "sent", "result": "\(r)"])
                    case "status":
                        let s = link.node.primary
                        emit(["event": "status", "phase": s?.phase.rawValue ?? "unpaired", "rtt": s?.rtt ?? -1,
                              "tasks": link.tasks.map { ["title": $0.title, "folders": $0.folderPaths] },
                              "sent": link.sent.map { ["uid": $0.uid, "state": $0.state.rawValue] }])
                    case "quit":
                        link.stop(); exit(0)
                    default:
                        emit(["event": "error", "line": String(line)])
                    }
                }
            }
        }
    }
}

app.run()
