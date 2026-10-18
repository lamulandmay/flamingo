import Foundation

/// Claude through the user's own Claude Code sign-in (`claude -p`), for a Mac that has Claude
/// Code but no API key. One pass with tools off: the passages are already in the prompt. Runs
/// in an empty folder so no project's CLAUDE.md or memory joins the conversation.
struct ClaudeCodeClient: Sendable {
    static let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    /// An app opened from Finder doesn't have the shell's PATH, so the usual installs are probed.
    static var executable: URL? {
        candidates.lazy
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    struct Reply: Sendable, Equatable {
        var text: String
        /// The model id Claude Code reports it ran, else the one asked for.
        var model: String
    }

    /// Streams text as it arrives; returns the whole answer. `model` is Settings' Claude model
    /// (a full id or an alias Claude Code knows); empty leaves Claude Code's own default.
    /// Cancelling the task ends the process.
    func send(system: String, user: String, model: String, onText: @escaping @Sendable (String) -> Void) async throws -> Reply {
        guard let exe = Self.executable else { throw AskError.unavailable("Claude Code is not installed") }
        let temp = FileManager.default.temporaryDirectory
        let cwd = temp.appendingPathComponent("flamingo-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        // The system prompt goes in a file only this user can read, not argv, where every
        // process on the Mac could see it while the answer runs.
        let promptFile = temp.appendingPathComponent("flamingo-ask-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: promptFile.path, contents: Data(system.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AskError.unavailable("Claude Code can't be started")
        }
        defer { try? FileManager.default.removeItem(at: promptFile) }

        let process = Process()
        process.executableURL = exe
        process.currentDirectoryURL = cwd
        process.arguments = Self.arguments(model: model, systemPromptFile: promptFile.path)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Set before `run`, so an exit that comes first is still heard; the stream buffers it.
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        // stderr drains alongside stdout: `--verbose` can fill its pipe, and a writer blocked
        // there would never finish stdout either.
        let stderr = Task.detached { () async throws -> Data in
            var data = Data()
            for try await byte in errors.fileHandleForReading.bytes {
                data.append(byte)
                if data.count > 16_384 { data.removeFirst(8_192) }
            }
            return data
        }
        // The question can be bigger than a pipe holds; writing it off the cooperative pool
        // keeps a slow reader from stalling a Swift concurrency thread.
        // A Claude Code that exits before reading it gets EPIPE here, not a SIGPIPE for Flamingo.
        let question = Data(user.utf8)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: question)
            try? input.fileHandleForWriting.close()
        }

        return try await withTaskCancellationHandler {
            var streamed = ""
            var result: String?
            var failure: String?
            var ran: String?
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "system":
                    if let m = event["model"] as? String, !m.isEmpty { ran = m }
                case "stream_event":
                    guard let e = event["event"] as? [String: Any] else { break }
                    if e["type"] as? String == "message_start",
                       let m = (e["message"] as? [String: Any])?["model"] as? String, !m.isEmpty { ran = m }
                    if e["type"] as? String == "content_block_delta",
                       let delta = e["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        streamed += text
                        onText(text)
                    }
                case "result":
                    if event["is_error"] as? Bool == true { failure = event["result"] as? String ?? "Claude Code failed" }
                    else { result = event["result"] as? String }
                default:
                    break
                }
            }
            for await _ in exited {}
            let log = (try? await stderr.value) ?? Data()
            try Task.checkCancellation()
            if let failure { throw AskError.stream(failure) }
            let label = ran ?? (model.isEmpty ? "claude" : model)
            if let text = result ?? (streamed.isEmpty ? nil : streamed) { return Reply(text: text, model: label) }
            let message = String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AskError.stream(message.isEmpty ? "Claude Code returned nothing" : String(message.suffix(300)))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// One pass, tools off, nothing saved; the system prompt read from `systemPromptFile`.
    static func arguments(model: String, systemPromptFile: String) -> [String] {
        var args = ["-p"]
        if !model.isEmpty { args += ["--model", model] }
        args += ["--tools", "", "--no-session-persistence",
                 "--system-prompt-file", systemPromptFile,
                 "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        return args
    }
}
