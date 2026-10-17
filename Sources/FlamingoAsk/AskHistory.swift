import Foundation

struct AskHistory: Codable, Sendable {
    var exchanges: [Exchange]
    var draft: String
    var currentFileOnly: Bool? = nil
}

enum AskHistoryStore {
    private static let queue = DispatchQueue(label: "com.flamingo.ask-history", qos: .utility)
    static func load(_ url: URL) throws -> AskHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return AskHistory(exchanges: [], draft: "") }
        return try JSONDecoder().decode(AskHistory.self, from: Data(contentsOf: url))
    }
    static func save(_ state: AskHistory, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    static func enqueue(_ state: AskHistory, to url: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do { try save(state, to: url); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
}
