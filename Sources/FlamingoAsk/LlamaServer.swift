import AppKit
import Foundation

/// Runs `llama-server` with the local 27B for Ask. Started on the first local question, kept
/// running, stopped when Flamingo quits.
///
/// Ports 8080…8089 are probed in order. A server already answering there with this model
/// (one Flamingo left behind after a crash, say) is reused and left running; a server that
/// isn't ours or wants a key is skipped; the first free port gets a new one.
public final class LlamaServer: @unchecked Sendable {
    public static let shared = LlamaServer()

    /// The alias the server answers to, and the line Ask shows while it loads.
    public static let modelName = "qwen3.8-27b"

    /// Custom model folders get a distinct server alias, so a leftover process for a
    /// previous folder cannot answer under the newly selected model's identity.
    public var modelAlias: String {
        guard UserDefaults.standard.string(forKey: "FlamingoLlamaModelDir") != nil else { return Self.modelName }
        guard let model = try? files().0 else { return Self.alias(for: modelDirectory.path) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: model.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Self.alias(for: model.path + "|\(stamp)|\(attrs?[.size] ?? 0)")
    }

    public var displayName: String {
        guard UserDefaults.standard.string(forKey: "FlamingoLlamaModelDir") != nil else { return Self.modelName }
        return (try? files().0.lastPathComponent) ?? modelDirectory.lastPathComponent
    }

    static func alias(for identity: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "flamingo-" + String(hash, radix: 16)
    }

    /// Where the GGUF and its vision projector live. `FlamingoLlamaModelDir` overrides.
    public var modelDirectory: URL {
        if let dir = UserDefaults.standard.string(forKey: "FlamingoLlamaModelDir") {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("codex/cgnsa/data/models/qwen3.8-27b")
    }

    static let binaries = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
    static let ports = 8080...8089
    static let contextSize = 16384

    private let lock = NSLock()
    private var process: Process?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?
    private var startingID: UUID?
    private var generation = 0
    private var observing = false
    private var _lastInteractiveUse: Date?
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    /// The `/v1` base URL of a healthy server, starting one if needed. `onLoading` runs once
    /// if the model has to load first (about 36 s).
    public func endpoint(onLoading: @escaping @Sendable () -> Void = {}) async throws -> URL {
        try await endpoint(background: false, onLoading: onLoading)
    }

    /// `background` marks a caller that isn't a person waiting (the night shift): it doesn't
    /// count as Ask using the server, so the night shift can stop a server it started itself.
    public func endpoint(background: Bool, onLoading: @escaping @Sendable () -> Void = {}) async throws -> URL {
        if !background { lock.withLock { _lastInteractiveUse = Date() } }
        let alias = modelAlias
        if let url = lock.withLock({ baseURL }) {
            if await health(url.deletingLastPathComponent()) == .ok,
               await servesModel(url.deletingLastPathComponent(), alias: alias) == true { return url }
            lock.withLock { if baseURL == url { baseURL = nil } }
        }
        let (task, id, epoch): (Task<URL, Error>, UUID, Int) = lock.withLock {
            if let starting, let startingID { return (starting, startingID, generation) }
            let id = UUID()
            let t = Task { try await self.locate(alias: alias, onLoading: onLoading) }
            starting = t
            startingID = id
            return (t, id, generation)
        }
        defer { lock.withLock { if startingID == id { starting = nil; startingID = nil } } }
        let url = try await task.value
        try Task.checkCancellation()
        let accepted = lock.withLock { () -> Bool in
            guard generation == epoch else { return false }
            baseURL = url; return true
        }
        guard accepted else { throw CancellationError() }
        return url
    }

    /// The URL of a healthy server that already serves the model, or nil. Never starts one:
    /// the understanding pass uses the 27B only when it is already loaded.
    public func runningEndpoint() async -> URL? {
        let alias = modelAlias
        if let url = lock.withLock({ baseURL }) {
            let root = url.deletingLastPathComponent()
            if await health(root) == .ok, await servesModel(root, alias: alias) == true { return url }
        }
        for port in Self.ports {
            let root = URL(string: "http://127.0.0.1:\(port)")!
            if await health(root) == .ok, await servesModel(root, alias: alias) == true { return root.appendingPathComponent("v1") }
        }
        return nil
    }

    /// When a person last asked for the server (Ask, `@ai`), nil if they never have this run.
    public var lastInteractiveUse: Date? { lock.withLock { _lastInteractiveUse } }

    /// Stops the server if Flamingo started it.
    public func stop() {
        let p = lock.withLock { () -> Process? in
            starting?.cancel(); starting = nil; startingID = nil; generation += 1
            defer { process = nil; baseURL = nil }
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }

    /// True while Flamingo's own server process is alive.
    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    // MARK: Internals

    enum Health: Equatable { case ok, loading, free, other }

    private func locate(alias: String, onLoading: @escaping @Sendable () -> Void) async throws -> URL {
        var announced = false
        for port in Self.ports {
            try Task.checkCancellation()
            let root = URL(string: "http://127.0.0.1:\(port)")!
            var state = await health(root)
            if state == .loading {
                guard await servesModel(root, alias: alias) == true else { continue }
                if !announced { announced = true; onLoading() }
                state = try await waitUntilHealthy(root, process: nil)
            }
            switch state {
            case .ok:
                if await servesModel(root, alias: alias) == true { return root.appendingPathComponent("v1") }
            case .free:
                if !announced { announced = true; onLoading() }
                return try await launch(port: port, root: root, alias: alias)
            case .loading, .other:
                break
            }
        }
        throw AskError.unavailable("No free port for llama-server")
    }

    private func launch(port: Int, root: URL, alias: String) async throws -> URL {
        guard let binary = Self.binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AskError.unavailable("llama-server isn't installed")
        }
        let (model, projector) = try files()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        var args = ["-m", model.path, "-c", "\(Self.contextSize)", "--host", "127.0.0.1", "--port", "\(port)",
                    "--jinja", "--alias", alias, "--no-webui"]
        if let projector { args += ["--mmproj", projector.path] }
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = Self.logHandle() ?? FileHandle.nullDevice
        try Task.checkCancellation()
        try p.run()
        let accepted = lock.withLock { () -> Bool in
            guard !Task.isCancelled else { return false }
            process = p; return true
        }
        guard accepted else { p.terminate(); throw CancellationError() }
        observeTermination()
        do { _ = try await waitUntilHealthy(root, process: p) }
        catch {
            if p.isRunning { p.terminate() }
            lock.withLock { if process === p { process = nil } }
            throw error
        }
        return root.appendingPathComponent("v1")
    }

    /// The model GGUF and, if present, the `mmproj` vision projector beside it.
    func files() throws -> (URL, URL?) {
        let dir = modelDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let ggufs = names.filter { $0.hasSuffix(".gguf") }.sorted()
        guard let model = ggufs.first(where: { !$0.lowercased().hasPrefix("mmproj") }) else {
            throw AskError.unavailable("No local model in \(dir.path)")
        }
        let projector = ggufs.first { $0.lowercased().hasPrefix("mmproj") }
        return (dir.appendingPathComponent(model), projector.map { dir.appendingPathComponent($0) })
    }

    private func waitUntilHealthy(_ root: URL, process: Process?) async throws -> Health {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            if let process, !process.isRunning { throw AskError.unavailable("llama-server stopped while loading") }
            let state = await health(root)
            if state == .ok { return .ok }
            if state == .other { throw AskError.unavailable("llama-server didn't start") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AskError.unavailable("\(Self.modelName) took too long to load")
    }

    /// `GET /health`: 200 ready, 503 loading, refused means nothing listens there.
    func health(_ root: URL) async -> Health {
        do {
            let (_, response) = try await session.data(from: root.appendingPathComponent("health"))
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return .ok
            case 503: return .loading
            default: return .other
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .free
        } catch {
            return .other
        }
    }

    /// Whether `/v1/models` lists the 27B. Nil when the server won't say (still loading).
    private func servesModel(_ root: URL, alias: String) async -> Bool? {
        guard let (data, response) = try? await session.data(from: root.appendingPathComponent("v1/models")) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 503 { return nil }
        guard status == 200, let json = try? JSON.decode(data) else { return false }
        let ids = (json["data"]?.array ?? []).compactMap { $0["id"]?.string?.lowercased() }
        return ids.contains(alias.lowercased())
    }

    private func observeTermination() {
        let first = lock.withLock { () -> Bool in defer { observing = true }; return !observing }
        guard first else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stop()
        }
    }

    private static func logHandle() -> FileHandle? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Flamingo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("llama-server.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }
}
