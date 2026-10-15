import Accelerate
import Foundation

/// `nomic-embed-text` through Ollama's `/api/embed`. Synchronous; callers are on background
/// threads, or pass a short timeout. Nil when Ollama isn't running or answers badly.
public struct Embedder: Sendable {
    public static let model = "nomic-embed-text"
    public var url = URL(string: "http://127.0.0.1:11434/api/embed")!
    var session: URLSession = .shared
    /// Tests swap in a fake; nil asks Ollama.
    var fake: (@Sendable ([String]) -> [[Float]]?)?

    /// About 512 tokens of text.
    static let maxChars = 2000

    public init() {}

    /// nomic wants a task prefix: `search_document: ` for what's stored, `search_query: ` for queries.
    static func document(title: String?, text: String) -> String {
        var s = ""
        if let title, !title.isEmpty { s = title + "\n" }
        s += text
        if s.count > maxChars { s = String(s.prefix(maxChars)) }
        return "search_document: " + s
    }

    static func query(_ q: String) -> String { "search_query: " + q }

    /// Unit-length vectors, one per input, or nil.
    func embed(_ inputs: [String], timeout: TimeInterval) -> [[Float]]? {
        guard !inputs.isEmpty else { return [] }
        if let fake { return fake(inputs).map { $0.map(Self.normalized) } }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": Self.model, "input": inputs, "keep_alive": "15m"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { task.cancel(); return nil }
        guard let data = box.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["embeddings"] as? [[NSNumber]], rows.count == inputs.count else { return nil }
        return rows.map { Self.normalized($0.map(\.floatValue)) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var scale = 1 / norm
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    private final class ResultBox: @unchecked Sendable { var data: Data? }
}

/// Every stored section vector in one contiguous Float32 matrix, for brute-force cosine.
final class VectorMatrix {
    let sections: [Int]
    let dim: Int
    let values: [Float]

    init(sections: [Int], dim: Int, values: [Float]) {
        self.sections = sections; self.dim = dim; self.values = values
    }

    var isEmpty: Bool { sections.isEmpty }

    /// The `limit` most similar sections at or above `floor`, best first.
    func nearest(_ query: [Float], limit: Int, floor: Float) -> [(section: Int, score: Float)] {
        guard !isEmpty, query.count == dim else { return [] }
        var scores = [Float](repeating: 0, count: sections.count)
        // (n × d) · (d × 1): each row is unit length, so the product is the cosine.
        vDSP_mmul(values, 1, query, 1, &scores, 1, vDSP_Length(sections.count), 1, vDSP_Length(dim))
        var hits: [(Int, Float)] = []
        for (i, s) in scores.enumerated() where s >= floor { hits.append((i, s)) }
        hits.sort { $0.1 > $1.1 }
        return hits.prefix(limit).map { (sections[$0.0], $0.1) }
    }

    static func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Background embedding state for one `IndexStore`.
final class EmbeddingState: @unchecked Sendable {
    let lock = NSLock()
    var scheduled = false
    var running = false
    var matrix: VectorMatrix?
    /// Recent query vectors, so typing in the palette doesn't re-embed the same prefix.
    var queries: [String: [Float]] = [:]
    /// When Ollama last failed; semantic search stays off for a while after.
    var downSince: Date?
    let queue = DispatchQueue(label: "flamingo.embeddings", qos: .background)
    var embedder = Embedder()
}

/// Reciprocal rank fusion: each list contributes 1 / (k + rank) for the items it has.
enum Fusion {
    static let k = 60.0

    static func fuse<T>(_ lists: [[T]], weights: [Double] = [], key: (T) -> String) -> [(item: T, score: Double)] {
        var best: [String: (item: T, score: Double, order: Int)] = [:]
        var order = 0
        for (l, list) in lists.enumerated() {
            let weight = l < weights.count ? weights[l] : 1
            for (rank, item) in list.enumerated() {
                let k = key(item)
                let add = weight / (Self.k + Double(rank + 1))
                if let e = best[k] { best[k] = (e.item, e.score + add, e.order) }
                else { best[k] = (item, add, order); order += 1 }
            }
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map { ($0.item, $0.score) }
    }
}
