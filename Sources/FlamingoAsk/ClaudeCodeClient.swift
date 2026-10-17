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

    var model = "sonnet"

    /// Streams text as it arrives; returns the whole answer. Cancelling the task ends the process.
    func send(system: String, user: String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let exe = Self.executable else { throw AskError.unavailable("Claude Code is not installed") }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = exe
        process.currentDirectoryURL = cwd
        process.arguments = ["-p", "--model", model, "--tools", "", "--no-session-persistence",
                             "--system-prompt", system,
                             "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(user.utf8))
        try? input.fileHandleForWriting.close()

        return try await withTaskCancellationHandler {
            var streamed = ""
            var result: String?
            var failure: String?
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "stream_event":
                    if let e = event["event"] as? [String: Any], e["type"] as? String == "content_block_delta",
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
            process.waitUntilExit()
            try Task.checkCancellation()
            if let failure { throw AskError.stream(failure) }
            if let text = result ?? (streamed.isEmpty ? nil : streamed) { return text }
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AskError.stream(stderr.isEmpty ? "Claude Code returned nothing" : String(stderr.suffix(300)))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
