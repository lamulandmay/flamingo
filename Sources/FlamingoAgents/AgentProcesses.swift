import Foundation
import Darwin

/// A coding agent's command-line harness (plan 18). Codex's desktop app-server runs from `/`,
/// so its live process says nothing about where it works; its logs do (`AgentLogs`).
public enum AgentHarness: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Harness processes running as this user, with their working folders. Reads the process
/// table through libproc; no special permission needed for one's own processes.
public enum AgentProcesses {
    public struct Found: Equatable, Sendable {
        public var pid: Int32
        public var harness: AgentHarness
        public var cwd: String

        public init(pid: Int32, harness: AgentHarness, cwd: String) {
            self.pid = pid; self.harness = harness; self.cwd = cwd
        }
    }

    /// Every harness process except Flamingo's own children (Ask runs `claude -p`). Looks at
    /// every process; `Scanner` remembers what each one runs and is the one to poll.
    public static func scan() -> [Found] { Scanner().scan() }

    /// Remembers which processes are harnesses, so a repeated scan only identifies new pids:
    /// identifying all of them takes about 40 ms, a repeat about 1 ms. A pid seen again with a
    /// different start time is a new process.
    public final class Scanner: @unchecked Sendable {
        private struct Known { var started: UInt64; var harness: AgentHarness? }
        private var known: [pid_t: Known] = [:]
        private let lock = NSLock()

        public init() {}

        public func scan() -> [Found] {
            lock.lock(); defer { lock.unlock() }
            let me = getpid()
            let estimate = proc_listallpids(nil, 0)
            guard estimate > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [] }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            var alive: [pid_t: Known] = [:]
            var out: [Found] = []
            for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
                guard let info = bsdInfo(pid) else { continue }
                let started = UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
                var entry = known[pid].flatMap { $0.started == started ? $0 : nil }
                if entry == nil {
                    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
                    let executable = String(cString: path)
                    let found = harness(executable: executable)
                        ?? ((executable as NSString).lastPathComponent == "node" ? harness(arguments: arguments(of: pid)) : nil)
                    entry = Known(started: started, harness: found)
                }
                alive[pid] = entry
                guard let harness = entry?.harness, pid_t(info.pbi_ppid) != me,
                      let cwd = workingFolder(of: pid), !cwd.isEmpty else { continue }
                out.append(Found(pid: pid, harness: harness, cwd: cwd))
            }
            known = alive
            return out
        }
    }

    /// Claude Code's native install runs as `~/.local/share/claude/versions/<version>`, so the
    /// kernel's process name is the version number. Match the executable path instead.
    static func harness(executable: String) -> AgentHarness? {
        let name = (executable as NSString).lastPathComponent
        if name == "claude" || executable.contains("/claude/versions/") { return .claudeCode }
        if name == "codex" { return .codex }
        return nil
    }

    /// An npm install runs under `node`; its script path names the package.
    static func harness(arguments: [String]) -> AgentHarness? {
        if arguments.contains(where: { $0.contains("@anthropic-ai/claude-code") || $0.hasSuffix("/bin/claude") }) { return .claudeCode }
        if arguments.contains(where: { $0.contains("@openai/codex") || $0.hasSuffix("/bin/codex") }) { return .codex }
        return nil
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// `argv` through `KERN_PROCARGS2`: argc, the executable path, padding, then argv.
    static func arguments(of pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var length = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &length, nil, 0) == 0, argmax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < Int(argc), i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
