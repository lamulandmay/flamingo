import Foundation

/// Runs a command-line tool and collects its output. Both pipes are drained concurrently so a
/// chatty tool can't deadlock on a full pipe buffer, and a hung tool is killed at `timeout`.
enum Subprocess {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Returns nil if the tool couldn't be launched. Output beyond `maxOutput` bytes per pipe is dropped.
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                    timeout: TimeInterval = 30, maxOutput: Int = 64 << 20) -> Output? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }

        let group = DispatchGroup()
        let stdout = Drain(), stderr = Drain()
        for (pipe, sink) in [(out, stdout), (err, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.read(pipe.fileHandleForReading, limit: maxOutput)
                group.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); exited.wait() }
        }
        group.wait()
        return Output(status: p.terminationStatus, stdout: stdout.data, stderr: stderr.data, timedOut: timedOut)
    }

    private final class Drain: @unchecked Sendable {
        var data = Data()
        func read(_ h: FileHandle, limit: Int) {
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            }
            try? h.close()
        }
    }
}
