import AppKit
import FlamingoCore

/// Expands an archive where it lies, as Archive Utility does. One item out keeps its own
/// name; several go into a folder named for the archive; nothing is overwritten ("name 2").
/// A downloaded archive's quarantine carries over to what comes out, so Gatekeeper still
/// checks an app inside. The work happens in a scratch folder on the same disk, so the
/// folder on show only ever sees finished items arrive.
///
/// Zips go through ditto, as Finder's do, so their resource forks and tags come back.
/// Tarballs go through the system's bsdtar. Everything else (RAR, 7z, CAB, ...) and whatever
/// those two fail on (encrypted zips, Deflate64, zstd) goes through the bundled 7-Zip.
enum Unarchiver {
    enum Failure: Error, Equatable {
        /// Encrypted, and the password was missing or wrong.
        case needsPassword
        case empty
        /// The archive's folder can't be written to.
        case readOnly
        /// Nothing could read it: the last tool's complaint.
        case unreadable(String)
    }

    struct Tools {
        var sevenZip: URL?
        var bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        var ditto = URL(fileURLWithPath: "/usr/bin/ditto")

        /// 7-Zip from Contents/Helpers; without it (a bare `swift build`), bsdtar reads most RAR and 7z.
        static var bundled: Tools {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
            return Tools(sevenZip: FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil)
        }
    }

    /// What double-click expands. Disk images and installers mount or install, and documents
    /// that are zips inside (docx, epub, jar, ipa) open in their apps, as in Finder.
    private static let archives: Set<String> = [
        "zip", "zipx", "rar", "7z", "cab", "arj", "lzh", "lha", "cpio", "rpm", "deb", "wim", "xar",
        "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "taz",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "zst", "z",
    ]
    private static let tarballs: Set<String> = ["tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "taz"]
    /// One compressed stream; "x.tar.gz" is a tarball.
    private static let streams: Set<String> = ["gz", "gzip", "bz2", "bzip2", "xz", "lzma", "zst", "z"]
    private static let leftovers: Set<String> = ["__MACOSX", ".DS_Store"]

    static func expands(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if archives.contains(ext) { return true }
        // A split archive's volume: x.7z.001.
        return isVolumeNumber(ext) && archives.contains(url.deletingPathExtension().pathExtension.lowercased())
    }

    /// The archive's name without its archive extensions: "Photos" for Photos.tar.gz,
    /// Photos.part1.rar and Photos.7z.001.
    static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        for _ in 0..<3 {
            let ext = (name as NSString).pathExtension.lowercased()
            guard archives.contains(ext) || isVolumeNumber(ext) || partNumber(ext) != nil else { break }
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? "Archive" : name
    }

    /// Where a multi-volume archive starts: x.part1.rar for x.part3.rar, x.7z.001 for x.7z.003.
    static func firstVolume(of url: URL) -> URL {
        let ext = url.pathExtension, stem = url.deletingPathExtension()
        var first: URL?
        if ext.lowercased() == "rar", let digits = partNumber(stem.pathExtension.lowercased()), Int(digits) != 1 {
            let part = "part" + String(repeating: "0", count: digits.count - 1) + "1"
            first = stem.deletingPathExtension().appendingPathExtension(part).appendingPathExtension(ext)
        } else if isVolumeNumber(ext), ext != "001" {
            first = stem.appendingPathExtension("001")
        }
        guard let first, FileManager.default.fileExists(atPath: first.path) else { return url }
        return first
    }

    /// Expands `archive` beside itself and returns what came out: its one item, or the folder
    /// holding several. Blocks; call it off the main thread.
    static func expand(_ archive: URL, password: String? = nil, tools: Tools = .bundled) throws -> URL {
        let fm = FileManager.default
        let archive = firstVolume(of: archive.standardizedFileURL)
        let folder = archive.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw Failure.readOnly }
        let scratch = try scratchFolder(near: folder)
        defer { try? fm.removeItem(at: scratch) }

        let out = try unpack(archive, password: password, tools: tools, in: scratch)
        var items = try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        for item in items where leftovers.contains(item.lastPathComponent) { try? fm.removeItem(at: item) }
        items.removeAll { leftovers.contains($0.lastPathComponent) }
        guard !items.isEmpty else { throw Failure.empty }
        if let quarantine = quarantine(of: archive) { mark(out, with: quarantine) }

        let one = items.count == 1 ? items[0] : nil
        let destination = freeName(one?.lastPathComponent ?? baseName(of: archive),
                                   in: folder, isFolder: one.map(isFolder) ?? true)
        try fm.moveItem(at: one ?? out, to: destination)
        return destination
    }

    /// "name", else "name 2", "name 3"..., before the extension for a file, as Finder names copies.
    static func freeName(_ name: String, in folder: URL, isFolder: Bool) -> URL {
        let ns = name as NSString
        let stem = isFolder || ns.pathExtension.isEmpty ? name : ns.deletingPathExtension
        let ext = isFolder ? "" : ns.pathExtension
        var url = folder.appendingPathComponent(name, isDirectory: isFolder)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || isLink(url) {
            let next = "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
            url = folder.appendingPathComponent(next, isDirectory: isFolder)
            n += 1
        }
        return url
    }

    // MARK: Tools

    private enum Tool { case ditto, bsdtar, sevenZip }

    /// The tools to try, best first.
    private static func plan(for archive: URL, password: String?, tools: Tools) -> [Tool] {
        let ext = archive.pathExtension.lowercased()
        let order: [Tool]
        if password != nil { order = [.sevenZip] }
        else if ext == "zip" { order = [.ditto, .sevenZip] }
        else if isTarball(archive) { order = [.bsdtar, .sevenZip] }
        else { order = [.sevenZip, .bsdtar] }
        return order.filter { $0 != .sevenZip || tools.sevenZip != nil }
    }

    /// Tries each tool into a fresh folder until one reads the archive; the folder it filled.
    private static func unpack(_ archive: URL, password: String?, tools: Tools, in scratch: URL) throws -> URL {
        var complaint = "No tool reads this archive", encrypted = false
        for tool in plan(for: archive, password: password, tools: tools) {
            let out = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let (status, message) = run(tool, archive, into: out, password: password, tools: tools)
            // 7-Zip's 1 is a warning, such as an attribute it couldn't set.
            if status == 0 || (tool == .sevenZip && status == 1) {
                // 7-Zip takes one layer off a compressed tarball; the tar inside is the archive.
                if tool == .sevenZip, isTarball(archive), archive.pathExtension.lowercased() != "tar",
                   let inner = onlyTar(in: out) {
                    return try unpack(inner, password: nil, tools: tools, in: scratch)
                }
                return out
            }
            Log.debug("expand \(archive.lastPathComponent): \(tool) \(status) \(message)")
            encrypted = encrypted || message.localizedCaseInsensitiveContains("password")
                || message.localizedCaseInsensitiveContains("encrypted")
            complaint = message.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: out)
        }
        throw encrypted ? Failure.needsPassword : Failure.unreadable(complaint)
    }

    /// Exit status and what the tool said on stderr. stdin is never a terminal, so no tool
    /// can stop to ask; 7-Zip reads a password from it, kept out of the process list.
    private static func run(_ tool: Tool, _ archive: URL, into out: URL, password: String?, tools: Tools) -> (Int32, String) {
        let process = Process()
        switch tool {
        case .ditto:
            process.executableURL = tools.ditto
            process.arguments = ["-x", "-k", "--sequesterRsrc", "--rsrc", archive.path, out.path]
        case .bsdtar:
            process.executableURL = tools.bsdtar
            process.arguments = ["-x", "-f", archive.path, "-C", out.path]
        case .sevenZip:
            process.executableURL = tools.sevenZip
            // An empty -p makes an encrypted archive fail with "Wrong password" instead of asking.
            process.arguments = ["x", "-y", "-bd", "-bso0", "-bsp0"] + (password == nil ? ["-p"] : [])
                + ["-o" + out.path, "--", archive.path]
        }
        if let password {
            // Written before launch, so the pipe's read end is open and a tool that never
            // reads it can't make the write fail.
            let input = Pipe()
            input.fileHandleForWriting.write(Data((password + "\n").utf8))
            try? input.fileHandleForWriting.close()
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        // Read before waiting, so a tool with a lot to say can't block on a full pipe.
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    // MARK: Pieces

    private static func isVolumeNumber(_ ext: String) -> Bool { ext.count == 3 && ext.allSatisfy(isDigit) }
    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// "3" for "part3".
    private static func partNumber(_ ext: String) -> Substring? {
        guard ext.hasPrefix("part") else { return nil }
        let digits = ext.dropFirst(4)
        return !digits.isEmpty && digits.allSatisfy(isDigit) ? digits : nil
    }

    private static func isTarball(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return tarballs.contains(ext) || (streams.contains(ext) && url.deletingPathExtension().pathExtension.lowercased() == "tar")
    }

    private static func onlyTar(in folder: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              items.count == 1, items[0].pathExtension.lowercased() == "tar", !isFolder(items[0]) else { return nil }
        return items[0]
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// On `folder`'s disk, so finished items move in with a rename.
    private static func scratchFolder(near folder: URL) throws -> URL {
        let fm = FileManager.default
        if let url = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) {
            return url
        }
        let url = folder.appendingPathComponent(".flamingo-expanding-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static let quarantineName = "com.apple.quarantine"

    private static func quarantine(of url: URL) -> Data? {
        let size = getxattr(url.path, quarantineName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, quarantineName, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }

    /// `folder` and everything in it, links themselves rather than what they point at.
    private static func mark(_ folder: URL, with quarantine: Data) {
        var urls = [folder]
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in walk { urls.append(url) }
        }
        for url in urls {
            _ = quarantine.withUnsafeBytes { setxattr(url.path, quarantineName, $0.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW) }
        }
    }
}

/// Archives being expanded, so a second double-click while one runs does nothing.
@MainActor
private enum Expansions {
    static var running = Set<String>()
}

extension AppState {
    /// Double-click (and ↩ in the columns and search results) on an archive expands it
    /// beside itself, as Finder does. False for anything else, which the caller opens as usual.
    @discardableResult
    func expandIfArchive(_ url: URL) -> Bool {
        guard Unarchiver.expands(url) else { return false }
        expand(url)
        return true
    }

    func expand(_ archive: URL, password: String? = nil) {
        let key = archive.standardizedFileURL.path
        guard Expansions.running.insert(key).inserted else { return }
        let progress = ToastMessage(text: "Expanding “\(archive.lastPathComponent)”…")
        // A quick one just appears; a slow one says what's happening.
        let notice = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.showToast(progress, duration: 3600)
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Unarchiver.expand(archive, password: password) }
            }.value
            notice.cancel()
            Expansions.running.remove(key)
            guard let self else { return }
            if self.toast?.id == progress.id { self.dismissToast() }
            self.expanded(archive, password: password, result: result)
        }
    }

    private func expanded(_ archive: URL, password: String?, result: Result<URL, Error>) {
        let name = archive.lastPathComponent
        switch result {
        case .success(let item):
            let folder = item.deletingLastPathComponent()
            noteFoldersChanged(FileMenu.vaultFolder(folder, state: self).map { [$0] } ?? [])
            // Still on the archive in the columns: what came out of it is selected instead.
            if mode == .files, selected == nil, browser.trail.last == ColumnBrowserModel.normal(archive) {
                browser.reveal(item, following: sidebarFolderURL)
            } else {
                showToast(ToastMessage(text: "Expanded “\(item.lastPathComponent)”", action: "Show",
                                       perform: { [weak self] in self?.revealExpanded(item) }))
            }
        case .failure(Unarchiver.Failure.needsPassword):
            askArchivePassword(archive, wrong: password != nil)
        case .failure(Unarchiver.Failure.empty):
            showToast(ToastMessage(text: "“\(name)” is empty"))
        case .failure(Unarchiver.Failure.readOnly):
            showToast(ToastMessage(text: "Can’t write in “\(archive.deletingLastPathComponent().lastPathComponent)”"))
        case .failure:
            showToast(ToastMessage(text: "Couldn’t expand “\(name)”"))
        }
    }

    private func revealExpanded(_ item: URL) {
        showFolder(item.deletingLastPathComponent(), focus: true)
        browser.reveal(item, following: sidebarFolderURL)
    }

    private func askArchivePassword(_ archive: URL, wrong: Bool) {
        let alert = NSAlert()
        let name = archive.lastPathComponent
        alert.messageText = wrong ? "Wrong password for “\(name)”" : "“\(name)” is encrypted"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Expand")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalentModifierMask = []
        alert.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.expand(archive, password: field.stringValue)
        }
        if let window = hostWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}
