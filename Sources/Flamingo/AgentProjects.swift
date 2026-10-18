import AppKit
import FlamingoCore
import FlamingoAgents

/// Plan 18 in the app: who is working where, the dot on folders an agent works in that aren't
/// projects yet, the Make Project sheet, No, and ⌘N's Project kind. Polls every 5 s while
/// Flamingo is in front and every 30 s behind; a repeat scan costs about a millisecond.
@MainActor
final class AgentProjectsModel: ObservableObject {
    /// What the sheet shows: the folder, what making it a project does, and who works there.
    struct Sheet: Identifiable {
        let root: URL
        let plan: ProjectConversion
        let activity: [AgentActivity]
        var error: String?
        var id: String { root.path }
        var name: String { root.lastPathComponent }
    }

    @Published private(set) var offers: [ProjectOffer] = []
    /// Vault-relative paths that carry the dot: each offered folder and every folder above it.
    @Published private(set) var dotted: Set<String> = []
    @Published var sheet: Sheet?

    weak var state: AppState?
    /// How offers are found off the main thread; tests replace it.
    var find: @Sendable (Vault, Set<String>, AgentProcesses.Scanner) -> [ProjectOffer] = { vault, declined, scanner in
        var presence = AgentPresence(vaultRoot: vault.root)
        presence.processes = scanner.scan
        return presence.offers(declined: declined)
    }
    private var vault: Vault?
    private var timer: Timer?
    private var last: Task<Void, Never>?
    private var queued = 0
    private let scanner = AgentProcesses.Scanner()
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(); self?.refresh() }
            })
        }
    }

    var isEnabled: Bool { Defaults.offerAgentProjects }

    func attach(_ vault: Vault?) {
        self.vault = vault
        sheet = nil
        publish([])
        schedule()
        refresh()
    }

    func settingChanged() {
        schedule()
        if isEnabled { refresh() } else { publish([]) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard vault != nil, isEnabled else { return }
        let interval: TimeInterval = NSApp?.isActive == false ? 30 : 5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval / 5
    }

    /// Scans off the main thread. A call while one runs queues one more behind it (never
    /// more), which reads the vault, the No list and `find` when it starts.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard vault != nil, isEnabled else { return nil }
        if queued > 0, let last { return last }
        let previous = last
        queued += 1
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.queued -= 1
            guard let vault = self.vault, self.isEnabled else { return }
            let scanner = self.scanner, find = self.find, declined = ProjectsStore(vault: vault).declined()
            let found = await Task.detached(priority: .utility) { find(vault, declined, scanner) }.value
            if self.vault == vault { self.publish(found) }
        }
        last = task
        return task
    }

    /// Republishes only when the folders change, not on every scan's newer timestamps.
    private func publish(_ found: [ProjectOffer]) {
        if found.map(\.root) != offers.map(\.root) { offers = found }
        var dots = Set<String>()
        for offer in found {
            guard var path = relativePath(offer.root) else { continue }
            while !path.isEmpty {
                dots.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        if dots != dotted { dotted = dots }
    }

    func relativePath(_ root: URL) -> String? {
        guard let vault else { return nil }
        return vault.relativePath(of: URL(fileURLWithPath: ProjectResolver.canonical(root.path)))
            ?? vault.relativePath(of: root)
    }

    /// One folder however it was reached: `/private/var` and `/var`, a symlink and its target.
    func same(_ a: URL, _ b: URL) -> Bool {
        ProjectResolver.canonical(a.path) == ProjectResolver.canonical(b.path)
    }

    func offer(at relativePath: String) -> ProjectOffer? {
        offers.first { self.relativePath($0.root) == relativePath }
    }

    /// The offer this dotted folder leads to: its own, or the first one inside it.
    func offer(under relativePath: String) -> ProjectOffer? {
        offer(at: relativePath) ?? offers.first { self.relativePath($0.root)?.hasPrefix(relativePath + "/") == true }
    }

    // MARK: Sheet

    func present(_ root: URL) {
        let activity = offers.first { same($0.root, root) }?.activity ?? []
        sheet = Sheet(root: root, plan: ProjectConverter.plan(root: root), activity: activity)
    }

    /// No: this folder isn't offered again. Make Project… stays in its context menu.
    func decline(_ root: URL) {
        sheet = nil
        guard let vault, let path = relativePath(root) else { return }
        try? ProjectsStore(vault: vault).decline(path)
        publish(offers.filter { !same($0.root, root) })
    }

    /// Converts the folder and registers one undo for all of it.
    func make(_ root: URL) {
        guard let state, let vault else { return }
        let plan = ProjectConverter.plan(root: root)
        do {
            var journal = try ProjectConverter.apply(plan)
            sheet = nil
            if let path = relativePath(root) { try? ProjectsStore(vault: vault).forget(path) }
            publish(offers.filter { !same($0.root, root) })
            changed(root)
            state.actionHistory.register(name: "Make Project", undo: { [weak self] in
                try journal.undo()
                self?.changed(root)
                self?.refresh()
            }, redo: { [weak self] in
                journal = try ProjectConverter.apply(ProjectConverter.plan(root: root, project: plan.marker.project))
                self?.changed(root)
                self?.refresh()
            })
        } catch {
            sheet?.error = error.localizedDescription
        }
    }

    /// ⌘N's Project kind: a new folder, structured from the start, with AGENTS.md open.
    func createProject(named name: String, in directory: URL) throws {
        guard let state, let vault else { return }
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = base, n = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(folder).path) {
            folder = "\(base) \(n)"; n += 1
        }
        let root = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let id = UUID()
        do {
            try ProjectScaffolder.apply(ProjectScaffolder.plan(root: root, name: folder, project: id))
        } catch {
            try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
            throw error
        }
        let written = Self.snapshot(ProjectChecker.structureItems, in: root)
        state.isNewFilePresented = false
        changed(root)
        if let rel = vault.relativePath(of: root.appendingPathComponent(ProjectStructure.agents)) {
            state.jump(to: FileRef(relativePath: rel), anchor: nil)
        }
        state.actionHistory.register(name: "New Project", undo: { [weak self] in
            try Self.verify(root, written: written, gitignoreAfter: nil)
            let top = Set(written.map { $0.path.components(separatedBy: "/")[0] })
            let inside = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).subtracting([".DS_Store"])
            guard inside.isSubset(of: top), !ProjectJournal.hasCommits(root) else { throw ProjectUndoError.changed }
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
            self?.changed(root)
        }, redo: { [weak self] in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try ProjectScaffolder.apply(ProjectScaffolder.plan(root: root, name: folder, project: id))
            self?.changed(root)
        })
    }

    private func changed(_ root: URL) {
        guard let state, let path = relativePath(root) else { return }
        state.noteFoldersChanged([path, (path as NSString).deletingLastPathComponent])
    }

    // MARK: Undo

    /// What Flamingo wrote, so undo can tell whether anyone changed it since.
    private static func snapshot(_ paths: [String], in root: URL) -> [(path: String, data: Data?)] {
        paths.map { path in
            let url = root.appendingPathComponent(path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return (path, isDir.boolValue ? nil : try? Data(contentsOf: url))
        }
    }

    /// Throws unless every file Flamingo wrote still holds its bytes and every folder it made
    /// holds only what Flamingo put there.
    private static func verify(_ root: URL, written: [(path: String, data: Data?)], gitignoreAfter: Data?) throws {
        let fm = FileManager.default
        for item in written where item.path != ".git" {
            let url = root.appendingPathComponent(item.path)
            if let data = item.data {
                guard (try? Data(contentsOf: url)) == data else { throw ProjectUndoError.changed }
            } else {
                let expected = Set(written.map(\.path).filter { $0.hasPrefix(item.path + "/") }.map { String($0.dropFirst(item.path.count + 1)) })
                guard let inside = try? fm.contentsOfDirectory(atPath: url.path),
                      Set(inside).subtracting([".DS_Store"]).isSubset(of: expected) else { throw ProjectUndoError.changed }
            }
        }
        if let gitignoreAfter, (try? Data(contentsOf: root.appendingPathComponent(ProjectStructure.gitignore))) != gitignoreAfter {
            throw ProjectUndoError.changed
        }
    }

}

private enum ProjectUndoError: LocalizedError {
    case changed
    var errorDescription: String? {
        "Undo stopped because the project's files changed since. Your current files are untouched."
    }
}

extension ProjectChecker {
    /// Every item the structure scaffolds, folders before what goes in them, plus `.git`.
    static var structureItems: [String] {
        [".git"] + ProjectStructure.folders
            + [ProjectStructure.agents, ProjectStructure.claude, ProjectStructure.readme, ProjectStructure.handover]
            + ProjectStructure.keepFiles + [ProjectStructure.gitignore]
    }
}
