import Foundation
import FlamingoCore

/// Per-app AppleScript probes for "which file, and where in it". Every script returns a
/// three-item list `{path, kind, value}`: `path` is a POSIX or HFS path (or empty), `kind`
/// is a `FileAnchor.Kind` raw value (or empty), `value` is text, a number, or an object
/// reference whose index is the value (Pages' `current page`). Property names were checked
/// against each app's `sdef`; scripts only ever run against the frontmost, already-running app.
enum AnchorScripts {
    struct Probe {
        let source: String
        /// The script knows better than `AXDocument` (Finder's window document is the folder,
        /// Xcode's may be the workspace).
        var pathWins = false
    }

    static let probes: [String: Probe] = [
        "com.apple.iWork.Keynote": Probe(source: iWork("com.apple.iWork.Keynote", anchor: """
                    set v to slide number of current slide of d
                    set k to "slide"
            """)),
        "com.apple.iWork.Numbers": Probe(source: iWork("com.apple.iWork.Numbers", anchor: """
                    set s to active sheet of d
                    set sn to name of s
                    set k to "sheet"
                    set v to sn
                    repeat with t in (every table of s)
                        try
                            set r to selection range of t
                            if r is not missing value then
                                set k to "cell"
                                set v to sn & "!" & (name of r)
                                exit repeat
                            end if
                        end try
                    end repeat
            """)),
        "com.apple.Pages": Probe(source: iWork("com.apple.Pages", anchor: """
                    set v to current page of d
                    set k to "page"
            """)),
        "com.apple.QuickTimePlayerX": Probe(source: iWork("com.apple.QuickTimePlayerX", anchor: """
                    set v to current time of d
                    set k to "time"
            """)),
        "com.apple.Preview": Probe(source: """
            set p to ""
            with timeout of 2 seconds
                tell application id "com.apple.Preview"
                    try
                        set p to path of front document
                    end try
                end tell
            end timeout
            return {p, "", ""}
            """),
        "com.apple.Music": Probe(source: """
            set p to missing value
            set k to ""
            set v to ""
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    try
                        set t to current track
                        if class of t is file track then set p to location of t
                        set v to player position
                        set k to "time"
                    end try
                end tell
            end timeout
            if p is not missing value then set p to POSIX path of p
            return {p, k, v}
            """),
        "com.apple.dt.Xcode": Probe(source: """
            set p to ""
            set k to ""
            set v to ""
            with timeout of 2 seconds
                tell application id "com.apple.dt.Xcode"
                    set wn to name of front window
                    set ds to every source document
                    set hit to missing value
                    repeat with d in ds
                        if wn ends with (name of d) then
                            set hit to d
                            exit repeat
                        end if
                    end repeat
                    if hit is missing value then
                        repeat with d in ds
                            if wn contains (name of d) then
                                set hit to d
                                exit repeat
                            end if
                        end repeat
                    end if
                    if hit is not missing value then
                        set p to path of hit
                        try
                            set v to item 1 of (selected paragraph range of hit)
                            set k to "line"
                        end try
                    end if
                end tell
            end timeout
            return {p, k, v}
            """, pathWins: true),
        "com.apple.finder": Probe(source: """
            set p to ""
            with timeout of 2 seconds
                tell application id "com.apple.finder"
                    set sel to selection
                    if (count of sel) > 0 then set p to (item 1 of sel) as alias
                end tell
            end timeout
            if p is not "" then set p to POSIX path of p
            return {p, "", ""}
            """, pathWins: true),
        "com.microsoft.Powerpoint": Probe(source: """
            set p to ""
            set k to ""
            set v to ""
            with timeout of 2 seconds
                tell application id "com.microsoft.Powerpoint"
                    try
                        set p to full name of active presentation
                    end try
                    try
                        if (count of slide show windows) > 0 then
                            set v to slide index of slide of slideshow view of slide show window 1
                            set k to "slide"
                        end if
                    end try
                    if k is "" then
                        try
                            set v to slide index of slide of view of active window
                            set k to "slide"
                        end try
                    end if
                end tell
            end timeout
            return {p, k, v}
            """),
        "com.microsoft.Excel": Probe(source: """
            set p to ""
            set k to ""
            set v to ""
            with timeout of 2 seconds
                tell application id "com.microsoft.Excel"
                    try
                        set p to full name of active workbook
                    end try
                    try
                        set sn to name of active sheet
                        set k to "sheet"
                        set v to sn
                        try
                            set a to get address selection
                            set k to "cell"
                            set v to sn & "!" & a
                        end try
                    end try
                end tell
            end timeout
            return {p, k, v}
            """),
        "com.microsoft.Word": Probe(source: """
            set p to ""
            set k to ""
            set v to ""
            with timeout of 2 seconds
                tell application id "com.microsoft.Word"
                    try
                        set p to full name of active document
                    end try
                    try
                        set v to get selection information selection information type active end adjusted page number
                        set k to "page"
                    end try
                end tell
            end timeout
            return {p, k, v}
            """),
    ]

    /// Keynote, Numbers, Pages and QuickTime share the Cocoa standard `file of document`.
    private static func iWork(_ bundleID: String, anchor: String) -> String {
        """
        set p to missing value
        set k to ""
        set v to ""
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                set d to front document
                try
                    set p to file of d
                end try
                try
        \(anchor)
                end try
            end tell
        end timeout
        if p is not missing value then set p to POSIX path of p
        return {p, k, v}
        """
    }

    // MARK: Running

    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    /// Runs the probe for `bundleID` on the calling thread. Nil when the app has no probe,
    /// isn't scriptable right now, or the user declined Automation (-1743).
    static func run(bundleID: String) -> (url: URL?, anchor: FileAnchor?)? {
        guard let probe = probes[bundleID] else { return nil }
        lock.lock(); defer { lock.unlock() }
        let script: NSAppleScript
        if let s = compiled[bundleID] {
            script = s
        } else {
            guard let s = NSAppleScript(source: probe.source) else { return nil }
            var err: NSDictionary?
            guard s.compileAndReturnError(&err) else { return nil }
            compiled[bundleID] = s
            script = s
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        guard err == nil, result.descriptorType == typeAEList, result.numberOfItems >= 3,
              let p = result.atIndex(1), let k = result.atIndex(2), let v = result.atIndex(3) else { return nil }
        return AnchorFormat.normalize(path: scalar(p), kind: scalar(k), value: scalar(v))
    }

    /// Text, numbers, and index-form object specifiers (`page 3 of document …`) as a string.
    static func scalar(_ d: NSAppleEventDescriptor) -> String? {
        switch d.descriptorType {
        case typeNull:
            return nil
        case typeType, typeEnumerated:
            return nil // `missing value` and friends
        case typeSInt16, typeSInt32, typeSInt64, typeUInt32:
            return String(d.int32Value)
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
            return AnchorFormat.number(d.doubleValue)
        case typeObjectSpecifier:
            guard let form = d.forKeyword(AEKeyword(keyAEKeyForm)), form.enumCodeValue == OSType(formAbsolutePosition),
                  let key = d.forKeyword(AEKeyword(keyAEKeyData)) else { return nil }
            let n = key.int32Value
            return n > 0 ? String(n) : nil
        default:
            let s = d.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }
    }
}

/// Pure formatting for what the probes and AX return. Unit-tested.
enum AnchorFormat {
    /// Turns raw probe output into a file URL and anchor.
    static func normalize(path: String?, kind: String?, value: String?,
                          bootVolume: String? = bootVolumeName) -> (url: URL?, anchor: FileAnchor?) {
        (url(fromPath: path, bootVolume: bootVolume), anchor(kind: kind, value: value))
    }

    static func anchor(kind: String?, value: String?) -> FileAnchor? {
        guard let kind, let k = FileAnchor.Kind(rawValue: kind),
              let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch k {
        case .time:
            guard let secs = Double(raw) else { return FileAnchor(kind: .time, value: raw) }
            return timecode(secs).map { FileAnchor(kind: .time, value: $0) }
        case .slide, .page, .line:
            guard let d = Double(raw), d >= 1, d.rounded() == d else { return nil }
            return FileAnchor(kind: k, value: String(Int(d)))
        case .cell:
            return FileAnchor(kind: .cell, value: cellReference(raw))
        default:
            return FileAnchor(kind: k, value: raw)
        }
    }

    /// `83.4` → `1:23`, `3723` → `1:02:03`.
    static func timecode(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let t = Int(seconds.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `Q3!$B$12:$C$14` → `Q3!B12:C14`. Only the reference after the last `!` loses its `$`.
    static func cellReference(_ raw: String) -> String {
        guard let bang = raw.lastIndex(of: "!") else { return raw.replacingOccurrences(of: "$", with: "") }
        let sheet = raw[..<bang]
        let ref = raw[raw.index(after: bang)...].replacingOccurrences(of: "$", with: "")
        return "\(sheet)!\(ref)"
    }

    /// Integral doubles without a trailing `.0`; others as-is.
    static func number(_ d: Double) -> String? {
        guard d.isFinite else { return nil }
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Accepts POSIX paths, `file://` URLs, and HFS paths (`Macintosh HD:Users:me:q3.pptx`,
    /// which Word and older Office builds return). Unsaved documents and cloud URLs → nil.
    static func url(fromPath raw: String?, bootVolume: String? = bootVolumeName) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://") { return URL(string: raw).flatMap { $0.isFileURL ? $0 : nil } }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if raw.contains("://") { return nil }
        guard let posix = posixPath(fromHFS: raw, bootVolume: bootVolume) else { return nil }
        return URL(fileURLWithPath: posix)
    }

    static func posixPath(fromHFS hfs: String, bootVolume: String?) -> String? {
        var parts = hfs.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let volume = parts.first, !volume.isEmpty else { return nil }
        if parts.last == "" { parts.removeLast() }
        let rest = parts.dropFirst().map { $0.replacingOccurrences(of: "/", with: ":") }
        let base = volume == bootVolume ? "" : "/Volumes/\(volume)"
        return base + "/" + rest.joined(separator: "/")
    }

    static var bootVolumeName: String? {
        try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    /// Preview and friends sometimes put `Page 4 of 12` in the window title.
    static func page(fromTitle title: String?) -> FileAnchor? {
        guard let title,
              let m = title.range(of: #"(?i)\bpage\s+(\d+)\s+of\s+\d+"#, options: .regularExpression) else { return nil }
        let digits = title[m].split(whereSeparator: { !$0.isNumber }).first
        return digits.flatMap { Int($0) }.map { FileAnchor(kind: .page, value: String($0)) }
    }
}
