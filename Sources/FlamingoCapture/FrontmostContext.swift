import AppKit
import ApplicationServices
import FlamingoCore

/// What the user is looking at in another app right now. Plan 03 owns.
///
/// The document comes from Accessibility (`AXDocument` on the focused window) and, for
/// apps that expose more, from a short AppleScript probe that also yields the anchor:
/// Keynote/PowerPoint slide, Numbers/Excel cell, Pages/Word/Preview page, QuickTime/Music
/// time, Xcode line, Finder's selected file. Unknown anchors are nil.
public struct FrontmostContext: Sendable {
    public var appBundleID: String
    public var documentURL: URL?
    public var sourceURL: URL? = nil
    public var anchor: FileAnchor?
    public var pid: pid_t = 0
    public var appName: String? = nil
    public var windowTitle: String? = nil
    /// The focused window in AppKit global coordinates (bottom-left origin), for centering
    /// the capture panel over it.
    public var windowFrame: CGRect? = nil
    /// The text selected in the app, up to 2,000 characters. Never read from a password field.
    public var selectedText: String? = nil
    /// Set by `current(in:)` when `documentURL` lies inside one of the given vaults.
    public var vault: Vault? = nil
    public var file: FileRef? = nil

    public init(appBundleID: String, documentURL: URL? = nil, anchor: FileAnchor? = nil, pid: pid_t = 0,
                appName: String? = nil, windowTitle: String? = nil, windowFrame: CGRect? = nil,
                vault: Vault? = nil, file: FileRef? = nil) {
        self.appBundleID = appBundleID; self.documentURL = documentURL; self.anchor = anchor; self.pid = pid
        self.appName = appName; self.windowTitle = windowTitle; self.windowFrame = windowFrame
        self.vault = vault; self.file = file
    }

    /// Flamingo itself is frontmost; use the in-app target instead.
    public var isFlamingo: Bool { pid == ProcessInfo.processInfo.processIdentifier }

    /// The frontmost app's document and anchor, without vault matching. Nil only when there
    /// is no frontmost app. Runs AppleScript on the calling thread; call from main.
    public static func current() -> FrontmostContext? {
        probe()
    }

    /// Like `current()`, plus `vault` and `file` when the document is a file the vault lists
    /// (the deepest root wins when vaults nest). Code editors without `AXDocument` (VS Code)
    /// fall back to the window title naming exactly one vault file. Still non-nil when nothing
    /// matched, so the caller can fall back to an inbox note.
    public static func current(in vaults: [Vault], candidates: [Vault: [FileRef]] = [:]) -> FrontmostContext? {
        guard var ctx = probe() else { return nil }
        guard !ctx.isFlamingo, !vaults.isEmpty else { return ctx }
        if let url = ctx.documentURL {
            if let (v, f) = locate(url, in: vaults), isListed(v.url(for: f), relativePath: f.relativePath) {
                ctx.vault = v; ctx.file = f
            }
        } else if titleFallbackApps(ctx.appBundleID), let title = ctx.windowTitle,
                  let (v, f) = titleMatch(title, in: vaults, candidates: candidates) {
            ctx.vault = v; ctx.file = f
            ctx.documentURL = v.url(for: f)
        }
        return ctx
    }

    /// Only what `VaultScanner` would list: a regular file or package, nothing hidden or
    /// ignored. Finder's folder windows and Terminal's working directory don't count.
    static func isListed(_ url: URL, relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0.hasPrefix(".") || VaultScanner.ignoredNames.contains($0) }) else { return false }
        let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
        return v?.isRegularFile == true || v?.isPackage == true
    }

    /// Editors that title windows after the open file but don't expose `AXDocument`. Other
    /// apps (a browser showing `report.pdf`) would match a vault file by coincidence.
    static func titleFallbackApps(_ bundleID: String) -> Bool {
        let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                    "com.todesktop.230313mt8jl8oz", "com.exafunction.windsurf", "dev.zed.Zed",
                                    "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova"]
        return editors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    // MARK: Accessibility permission

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt at most once per launch. Returns whether trusted.
    @discardableResult
    public static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        promptLock.lock(); defer { promptLock.unlock() }
        guard !didPrompt else { return false }
        didPrompt = true
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static let promptLock = NSLock()
    nonisolated(unsafe) private static var didPrompt = false

    // MARK: Probing

    private static func probe() -> FrontmostContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var ctx = FrontmostContext(appBundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                                   appName: app.localizedName)
        if ctx.isFlamingo { return ctx }

        let window = AXFrontmost.focusedWindow(pid: app.processIdentifier)
        ctx.windowTitle = window?.title
        ctx.windowFrame = window?.frame
        ctx.documentURL = window?.documentURL
        ctx.sourceURL = window?.sourceURL
        ctx.selectedText = AXFrontmost.selectedText(pid: app.processIdentifier)

        if let scripted = AnchorScripts.run(bundleID: ctx.appBundleID) {
            let pathWins = AnchorScripts.probes[ctx.appBundleID]?.pathWins ?? false
            if let s = scripted.url, pathWins || ctx.documentURL == nil {
                ctx.documentURL = s
                ctx.anchor = scripted.anchor
            } else if let s = scripted.url, let ax = ctx.documentURL, samePath(s, ax) {
                ctx.anchor = scripted.anchor
            } else if scripted.url == nil, ctx.documentURL != nil {
                // The script found an anchor but not a path (e.g. Preview's front document
                // isn't saved yet); trust it only for the focused document.
                ctx.anchor = scripted.anchor
            }
        }
        if ctx.anchor == nil, ctx.appBundleID == "com.apple.Preview" {
            ctx.anchor = AnchorFormat.page(fromTitle: ctx.windowTitle)
        }
        if ctx.sourceURL == nil { ctx.sourceURL = ctx.documentURL ?? browserURL(bundleID: ctx.appBundleID) }
        return ctx
    }

    private static func browserURL(bundleID: String) -> URL? {
        let expression: String
        switch bundleID {
        case "com.apple.Safari": expression = "URL of current tab of front window"
        case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser": expression = "URL of active tab of front window"
        default: return nil
        }
        let script = NSAppleScript(source: "with timeout of 1 seconds\n tell application id \"\(bundleID)\" to return \(expression)\nend timeout")
        var error: NSDictionary?
        guard let raw = script?.executeAndReturnError(&error).stringValue, error == nil,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url
    }

    // MARK: Vault matching

    /// The vault containing `url` and the file's ref in it. Paths are compared both
    /// standardized and with symlinks resolved (`/var` vs `/private/var`); packages with a
    /// trailing slash match their file. The deepest vault root wins.
    static func locate(_ url: URL, in vaults: [Vault]) -> (Vault, FileRef)? {
        let forms = pathForms(url)
        var best: (vault: Vault, file: FileRef, depth: Int)?
        for v in vaults {
            let depth = v.root.resolvingSymlinksInPath().pathComponents.count
            for root in pathForms(v.root) {
                let prefix = root == "/" ? "/" : root + "/"
                guard let p = forms.first(where: { $0.hasPrefix(prefix) }) else { continue }
                let rel = String(p.dropFirst(prefix.count))
                guard !rel.isEmpty, rel != ".flamingo", !rel.hasPrefix(".flamingo/") else { break }
                if depth > (best?.depth ?? -1) { best = (v, FileRef(relativePath: rel), depth) }
                break
            }
        }
        return best.map { ($0.vault, $0.file) }
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        !Set(pathForms(a)).isDisjoint(with: pathForms(b))
    }

    private static func pathForms(_ url: URL) -> [String] {
        func trimmed(_ p: String) -> String {
            var p = p
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        let std = trimmed(url.standardizedFileURL.path)
        let resolved = trimmed(url.resolvingSymlinksInPath().standardizedFileURL.path)
        var forms = [std]
        // `resolvingSymlinksInPath` drops `/private`; AX and AppleScript may keep it.
        let privateForms = [std, resolved].compactMap { p in
            ["/var/", "/tmp/", "/etc/"].contains(where: { p.hasPrefix($0) }) ? "/private" + p : nil
        }
        for p in [resolved] + privateForms where !forms.contains(p) { forms.append(p) }
        return forms
    }

    /// Exactly one vault file whose name stands as a whole token in `title`
    /// (`● q3.pptx — decks`), else nil.
    static func titleMatch(_ title: String, in vaults: [Vault]) -> (Vault, FileRef)? {
        titleMatch(title, in: vaults, candidates: Dictionary(uniqueKeysWithValues: vaults.map { ($0, TitleIndex.files(in: $0)) }))
    }

    static func titleMatch(_ title: String, in vaults: [Vault], candidates: [Vault: [FileRef]]) -> (Vault, FileRef)? {
        var hits: [(Vault, FileRef)] = []
        for v in vaults {
            for f in candidates[v] ?? [] where titleContains(title, name: f.name) {
                hits.append((v, f))
                if hits.count > 1 { return nil }
            }
        }
        return hits.first
    }

    static func titleContains(_ title: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        var search = title.startIndex..<title.endIndex
        while let r = title.range(of: name, options: [.caseInsensitive], range: search) {
            let beforeOK = r.lowerBound == title.startIndex || isBoundary(title[title.index(before: r.lowerBound)])
            let afterOK = r.upperBound == title.endIndex || isBoundary(title[r.upperBound])
            if beforeOK && afterOK { return true }
            search = title.index(after: r.lowerBound)..<title.endIndex
        }
        return false
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c.isWhitespace || "—–-|•●·:()[]\"'“”‘’<>,;".contains(c)
    }
}

/// Vault file lists for the title fallback, rescanned at most every 30 seconds.
private enum TitleIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: (at: Date, files: [FileRef])] = [:]

    static func files(in vault: Vault) -> [FileRef] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[vault.root], Date().timeIntervalSince(hit.at) < 30 { return hit.files }
        let files = VaultScanner.files(in: vault)
        cache[vault.root] = (Date(), files)
        return files
    }
}
