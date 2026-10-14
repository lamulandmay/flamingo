import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// ⌘K / ⌘F floating panel. Placeholder until the real one lands. Plan 01 owns.
@MainActor
final class PaletteController {
    static let shared = PaletteController()
    private(set) var isVisible = false
    func show(mode: PaletteMode, state: AppState) {}
    func hide() {}
}
