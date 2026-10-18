import AppKit
import SwiftUI
import FlamingoExtract

// `Flamingo --extract-model <file>`: a short-lived copy that reads one 3D file and exits, so
// ModelIO's USD threads never live in the app (ModelExtractor.helper).
ModelExtractor.runHelperIfAsked()
ModelExtractor.helper = Bundle.main.executablePath

// Bare-executable bootstrap so `swift run Flamingo` (and scripts/run.sh) shows a real
// window with menus, Dock presence and key handling. Plan 01 owns.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
