// Prints the CGWindowID of the frontmost on-screen window owned by the named app.
// Usage: window-id [AppName]   (used by scripts/screens.sh for `screencapture -l`)
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Flamingo"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.first {
    $0[kCGWindowOwnerName as String] as? String == owner && ($0[kCGWindowLayer as String] as? Int) == 0
        && (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) > 300
}
guard let id = match?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
