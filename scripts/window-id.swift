// Prints the CGWindowID of the main (largest) on-screen window owned by the named app, or with
// --bounds its frame as x,y,w,h for `screencapture -R` (which also picks up floating panels).
// Usage: window-id [--bounds] [--pid N] [AppName]   (used by scripts/screens.sh)
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let bounds = args.first == "--bounds"
if bounds { args.removeFirst() }
var pid: Int?
if args.first == "--pid", args.count > 1 { pid = Int(args[1]); args.removeFirst(2) }
let owner = args.first ?? "Flamingo"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
// The main window is the largest one; child panels (palette, capture) are smaller.
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
let match = list.filter {
    $0[kCGWindowOwnerName as String] as? String == owner && ($0[kCGWindowLayer as String] as? Int) == 0
        && (pid == nil || $0[kCGWindowOwnerPID as String] as? Int == pid)
        && (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) > 300
}.max { area($0) < area($1) }
guard let w = match, let id = w[kCGWindowNumber as String] as? Int else { exit(1) }
if bounds, let b = w[kCGWindowBounds as String] as? [String: Double] {
    print([b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!].map { String(Int($0)) }.joined(separator: ","))
} else {
    print(id)
}
