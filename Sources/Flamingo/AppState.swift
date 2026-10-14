import Foundation
import SwiftUI
import FlamingoCore

/// Single source of truth for the shell. Plan 01 owns.
@MainActor
final class AppState: ObservableObject {
    @Published var vault: Vault?
    @Published var files: [FileRef] = []
    @Published var selected: FileRef?
    @Published var anchor: FileAnchor?
    enum Mode { case files, graph, trail, ask }
    @Published var mode: Mode = .files

    func open(_ url: URL) {
        let v = Vault(root: url)
        vault = v
        files = VaultScanner.files(in: v)
        UserDefaults.standard.set(url.path, forKey: "lastVault")
    }

    func restoreLastVault() {
        if let p = UserDefaults.standard.string(forKey: "lastVault") { open(URL(fileURLWithPath: p)) }
    }
}
