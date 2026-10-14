import AppKit
import SwiftUI

// Bare-executable bootstrap so `swift run Flamingo` (and scripts/run.sh) shows a real
// window with menus, Dock presence and key handling. Plan 01 owns.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
