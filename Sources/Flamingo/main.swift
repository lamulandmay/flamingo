import AppKit
import SwiftUI

// Bare-executable bootstrap so `swift run Flamingo` shows a real window. Plan 01 owns.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
