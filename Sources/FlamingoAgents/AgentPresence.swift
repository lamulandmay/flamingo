import Foundation
import FlamingoCore

/// One agent working in a project folder.
public struct AgentActivity: Equatable, Sendable {
    public var project: URL
    public var harness: AgentHarness
    /// The log's session id; nil for a process whose log hasn't been matched.
    public var session: String?
    public var title: String?
    public var lastActive: Date
    /// A harness process is running there now.
    public var isLive: Bool

    public init(project: URL, harness: AgentHarness, session: String?, title: String?, lastActive: Date, isLive: Bool) {
        self.project = project; self.harness = harness; self.session = session
        self.title = title; self.lastActive = lastActive; self.isLive = isLive
    }
}

/// A folder an agent works in that isn't a project yet: the dot and the unresolved issue.
public struct ProjectOffer: Equatable, Sendable, Identifiable {
    public var root: URL
    public var activity: [AgentActivity]
    public var id: String { root.path }

    public init(root: URL, activity: [AgentActivity]) { self.root = root; self.activity = activity }
}

/// Who is working where, from live processes and recent logs (plan 18).
public struct AgentPresence {
    public var resolver: ProjectResolver
    public var logs: AgentLogs
    /// A log written this recently counts as working.
    public var window: TimeInterval = 15 * 60
    public var processes: () -> [AgentProcesses.Found] = AgentProcesses.Scanner().scan

    public init(vaultRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        resolver = ProjectResolver(vaultRoot: vaultRoot, home: home)
        logs = AgentLogs(home: home)
    }

    /// Everything working inside the vault, newest first, one entry per project and harness.
    public func activity(now: Date = Date()) -> [AgentActivity] {
        var byKey: [String: AgentActivity] = [:]
        func add(_ item: AgentActivity) {
            let key = item.project.path + "|" + item.harness.rawValue
            guard var existing = byKey[key] else { byKey[key] = item; return }
            existing.isLive = existing.isLive || item.isLive
            if item.lastActive > existing.lastActive || existing.session == nil {
                existing.lastActive = max(existing.lastActive, item.lastActive)
                existing.session = item.session ?? existing.session
                existing.title = item.title ?? existing.title
            }
            byKey[key] = existing
        }
        for found in processes() {
            guard let project = resolver.project(for: found.cwd) else { continue }
            add(AgentActivity(project: project, harness: found.harness, session: nil, title: nil, lastActive: now, isLive: true))
        }
        for session in logs.recent(since: now.addingTimeInterval(-window), now: now) {
            guard let project = resolver.project(for: session.cwd) else { continue }
            add(AgentActivity(project: project, harness: session.harness, session: session.id, title: session.title,
                              lastActive: session.lastActive, isLive: false))
        }
        return byKey.values.sorted { $0.lastActive > $1.lastActive }
    }

    /// Folders to offer: agents work there, they aren't projects, and nobody said no.
    /// `declined` holds vault-relative paths (`ProjectsStore`).
    public func offers(now: Date = Date(), declined: Set<String> = []) -> [ProjectOffer] {
        let grouped = Dictionary(grouping: activity(now: now), by: \.project)
        return grouped.compactMap { root, activity in
            let relative = String(root.path.dropFirst(resolver.vaultRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !declined.contains(relative), !Self.isProject(root) else { return nil }
            return ProjectOffer(root: root, activity: activity)
        }
        .sorted { ($0.activity.first?.lastActive ?? .distantPast) > ($1.activity.first?.lastActive ?? .distantPast) }
    }

    /// Carries the marker, whatever else it's missing (the keeper handles the rest).
    public static func isProject(_ root: URL) -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent(ProjectStructure.agents), encoding: .utf8) else { return false }
        return ProjectMarker.find(in: text) != nil
    }
}

/// `<vault>/.flamingo/projects.json`: the folders the user said no to. Paths are relative to
/// the vault root. A No lasts until the folder is made a project from its context menu.
public struct ProjectsStore {
    public static let fileName = "projects.json"
    public let url: URL

    public init(vault: Vault) { url = vault.stateDir.appendingPathComponent(Self.fileName) }

    private struct File: Codable { var declined: [String] = [] }

    public func declined() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return Set(file.declined)
    }

    public func decline(_ relativePath: String) throws { try write(declined().union([relativePath])) }

    public func forget(_ relativePath: String) throws { try write(declined().subtracting([relativePath])) }

    private func write(_ declined: Set<String>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(File(declined: declined.sorted())).write(to: url, options: .atomic)
    }
}
