import Accelerate
import Foundation
import NaturalLanguage
import FlamingoCore

/// How one embedding model wants its inputs worded, and how to read its cosine scores.
/// Vectors are only comparable within one `id`; the id is stored with every vector.
public struct EmbeddingProfile: Sendable, Hashable {
    public enum Backend: Sendable, Hashable {
        /// A model served by Ollama, by its tag (`qwen3-embedding:0.6b`).
        case ollama(String)
        /// Apple's on-device `NLContextualEmbedding` (Latin and CJK models), mean-pooled.
        case apple
        /// Tests.
        case fake
    }

    enum DocumentStyle: Sendable, Hashable { case plain, nomic, gemma }

    public let backend: Backend
    /// What's stored in `embedding_spans.model`.
    public let id: String
    /// `{q}` is replaced by the query.
    let queryTemplate: String
    let documentStyle: DocumentStyle
    /// Below this cosine a passage is unrelated to a query; at `strong` it plainly answers it.
    /// Calibrated on the benchmark in SEMANTIC.md.
    let floor: Float
    let strong: Float
    /// File-to-file cosines (means of chunk vectors) run higher than query-to-passage ones.
    let relatedFloor: Float
    /// Matryoshka models keep only this many leading dimensions in memory.
    let memoryDimensions: Int?
    /// Lower is better when several models are installed.
    let rank: Int
    /// Ollama context window to request; nil leaves the model's default.
    let contextLength: Int?

    func query(_ q: String) -> String { queryTemplate.replacingOccurrences(of: "{q}", with: q) }

    func document(header: String, body: String) -> String {
        switch documentStyle {
        case .plain: return header.isEmpty ? body : header + "\n" + body
        case .nomic: return "search_document: " + (header.isEmpty ? body : header + "\n" + body)
        case .gemma: return "title: " + (header.isEmpty ? "none" : header) + " | text: " + body
        }
    }

    /// Maps a cosine onto 0…1: 0 at the floor, 1 at `strong` or above.
    func relevance(_ cosine: Float) -> Double {
        Double(max(0, min(1, (cosine - floor) / max(0.01, strong - floor))))
    }

    static let apple = EmbeddingProfile(backend: .apple, id: "apple-nl-contextual", queryTemplate: "{q}", documentStyle: .plain,
                                        floor: 0.8, strong: 0.9, relatedFloor: 0.92, memoryDimensions: nil, rank: 90, contextLength: nil)
    static let fake = EmbeddingProfile(backend: .fake, id: "fake", queryTemplate: "search_query: {q}", documentStyle: .nomic,
                                       floor: 0.55, strong: 0.8, relatedFloor: 0.55, memoryDimensions: nil, rank: 99, contextLength: nil)

    /// Known Ollama embedding models, best first. Unknown models whose name says "embed"
    /// are used plainly, after these.
    static let known: [(base: String, make: (String) -> EmbeddingProfile)] = [
        ("qwen3-embedding", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "Instruct: Given a search query, retrieve passages from the user's files that answer it\nQuery: {q}",
                                               documentStyle: .plain, floor: 0.36, strong: 0.66, relatedFloor: 0.62, memoryDimensions: 512, rank: 0, contextLength: 2048) }),
        ("embeddinggemma", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "task: search result | query: {q}",
                                              documentStyle: .gemma, floor: 0.33, strong: 0.55, relatedFloor: 0.6, memoryDimensions: 512, rank: 1, contextLength: 2048) }),
        ("bge-m3", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "{q}", documentStyle: .plain,
                                      floor: 0.45, strong: 0.65, relatedFloor: 0.65, memoryDimensions: nil, rank: 2, contextLength: 2048) }),
        ("snowflake-arctic-embed2", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "query: {q}", documentStyle: .plain,
                                                       floor: 0.3, strong: 0.5, relatedFloor: 0.55, memoryDimensions: nil, rank: 3, contextLength: 2048) }),
        ("mxbai-embed-large", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "Represent this sentence for searching relevant passages: {q}",
                                                 documentStyle: .plain, floor: 0.5, strong: 0.7, relatedFloor: 0.7, memoryDimensions: nil, rank: 4, contextLength: nil) }),
        ("nomic-embed-text", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "search_query: {q}", documentStyle: .nomic,
                                                floor: 0.52, strong: 0.68, relatedFloor: 0.78, memoryDimensions: nil, rank: 5, contextLength: nil) }),
        ("granite-embedding", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "{q}", documentStyle: .plain,
                                                 floor: 0.5, strong: 0.7, relatedFloor: 0.7, memoryDimensions: nil, rank: 6, contextLength: nil) }),
        ("paraphrase-multilingual", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "{q}", documentStyle: .plain,
                                                       floor: 0.45, strong: 0.7, relatedFloor: 0.7, memoryDimensions: nil, rank: 7, contextLength: nil) }),
        ("all-minilm", { EmbeddingProfile(backend: .ollama($0), id: $0, queryTemplate: "{q}", documentStyle: .plain,
                                          floor: 0.35, strong: 0.6, relatedFloor: 0.6, memoryDimensions: nil, rank: 8, contextLength: nil) }),
    ]

    /// The profile for a stored model id, whatever is installed now.
    static func forID(_ id: String) -> EmbeddingProfile? {
        if id == apple.id { return apple }
        if id == fake.id { return fake }
        return ollama(id)
    }

    static func ollama(_ name: String) -> EmbeddingProfile? {
        let base = String(name.split(separator: ":").first ?? "").lowercased()
        let short = base.split(separator: "/").last.map(String.init) ?? base
        if let k = known.first(where: { short == $0.base || short.hasPrefix($0.base) }) { return k.make(name) }
        guard short.contains("embed") || short.contains("minilm") || short.contains("bge") else { return nil }
        return EmbeddingProfile(backend: .ollama(name), id: name, queryTemplate: "{q}", documentStyle: .plain,
                                floor: 0.45, strong: 0.7, relatedFloor: 0.7, memoryDimensions: nil, rank: 50, contextLength: nil)
    }
}

/// Produces embeddings: through Ollama when an embedding model is installed and running,
/// else Apple's on-device model, else nothing (search stays keyword-only). Synchronous;
/// callers are on background threads or pass a short timeout.
public struct Embedder: Sendable {
    /// The model the index used before profiles existed. Kept for source compatibility.
    public static let model = "nomic-embed-text"
    public var url = URL(string: "http://127.0.0.1:11434/api/embed")!
    var session: URLSession = .shared
    /// Tests swap in a fake; nil asks Ollama or Apple.
    var fake: (@Sendable ([String]) -> [[Float]]?)?
    /// An Ollama model tag, `apple`, or `none`. Nil picks the best installed model.
    /// Defaults to the `FlamingoEmbedModel` user default or `FLAMINGO_EMBED_MODEL`.
    public var preferred: String? = Embedder.defaultPreference

    /// About 512 tokens of text, the most one model input holds.
    static let maxChars = 2000

    public init() {}

    public static var defaultPreference: String? {
        if let env = ProcessInfo.processInfo.environment["FLAMINGO_EMBED_MODEL"], !env.isEmpty { return env }
        return UserDefaults.standard.string(forKey: "FlamingoEmbedModel")
    }

    // MARK: Legacy helpers (nomic wording), kept for callers and tests of the old format.

    static func document(title: String?, text: String) -> String {
        var s = ""
        if let title, !title.isEmpty { s = title + "\n" }
        s += text
        if s.count > maxChars { s = String(s.prefix(maxChars)) }
        return "search_document: " + s
    }

    static func query(_ q: String) -> String { "search_query: " + q }

    // MARK: Choosing a model

    /// The model new vectors should be made with right now, or nil when none can run.
    /// `current` (the model already in the index) is kept while it is still available and
    /// nothing better is installed; when its server is down nothing is chosen, so a vault is
    /// never half re-embedded with a weaker model just because Ollama was asleep.
    func resolve(current: String? = nil) -> EmbeddingProfile? {
        if fake != nil { return .fake }
        let preference = preferred?.trimmingCharacters(in: .whitespaces).lowercased()
        if preference == "none" || preference == "off" { return nil }
        if preference == "apple" { return AppleEmbedder.shared.isAvailable ? .apple : nil }
        let catalog = OllamaCatalog.shared.models(base: url)
        if let preferred, preference?.isEmpty == false {
            if let installed = catalog, let name = installed.first(where: { $0 == preferred || $0 == preferred + ":latest" || $0.hasPrefix(preferred + ":") }) {
                return EmbeddingProfile.ollama(name) ?? EmbeddingProfile(backend: .ollama(name), id: name, queryTemplate: "{q}", documentStyle: .plain,
                                                                          floor: 0.45, strong: 0.7, relatedFloor: 0.7, memoryDimensions: nil, rank: 50, contextLength: nil)
            }
            return nil
        }
        let best = catalog.flatMap { names in
            names.compactMap(EmbeddingProfile.ollama).min { ($0.rank, $0.id.count) < ($1.rank, $1.id.count) }
        }
        if let current, let profile = EmbeddingProfile.forID(current) {
            switch profile.backend {
            case .ollama:
                // Down: wait for it rather than switching models.
                guard let catalog else { return nil }
                if catalog.contains(current), best.map({ $0.rank >= profile.rank }) ?? true { return profile }
            case .apple:
                if best == nil { return AppleEmbedder.shared.isAvailable ? profile : nil }
            case .fake: break
            }
        }
        if let best { return best }
        return AppleEmbedder.shared.isAvailable ? .apple : nil
    }

    /// Whether `profile` can embed a query right now without waiting on a network timeout.
    func canEmbed(_ profile: EmbeddingProfile) -> Bool {
        switch profile.backend {
        case .fake: return fake != nil
        case .apple: return fake == nil && AppleEmbedder.shared.isAvailable
        case .ollama(let name): return fake == nil && (OllamaCatalog.shared.cachedModels(base: url)?.contains(name) ?? !OllamaCatalog.shared.isDown(base: url))
        }
    }

    // MARK: Embedding

    /// Unit-length vectors, one per input, or nil.
    func embed(_ inputs: [String], profile: EmbeddingProfile, timeout: TimeInterval, completion: (@Sendable ([[Float]]?) -> Void)? = nil) -> [[Float]]? {
        guard !inputs.isEmpty else { return [] }
        if let fake { return fake(inputs).map { $0.map(Self.normalized) } }
        switch profile.backend {
        case .fake: return nil
        case .apple: return AppleEmbedder.shared.embed(inputs)
        case .ollama(let name): return ollama(name, inputs, contextLength: profile.contextLength, timeout: timeout, completion: completion)
        }
    }

    /// Legacy entry point: nomic through Ollama.
    func embed(_ inputs: [String], timeout: TimeInterval) -> [[Float]]? {
        if let fake { return fake(inputs).map { $0.map(Self.normalized) } }
        return ollama(Self.model, inputs, contextLength: nil, timeout: timeout, completion: nil)
    }

    /// `completion` also receives the result when this call gives up waiting first, so a
    /// slow first query (model loading) still warms the cache for the next keystroke.
    private func ollama(_ name: String, _ inputs: [String], contextLength: Int?, timeout: TimeInterval, completion: (@Sendable ([[Float]]?) -> Void)?) -> [[Float]]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The request outlives a short wait so it can finish loading the model.
        request.timeoutInterval = max(timeout, completion == nil ? timeout : 60)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["model": name, "input": inputs, "keep_alive": "30m", "truncate": true]
        if let contextLength { body["options"] = ["num_ctx": contextLength] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let count = inputs.count
        let base = url
        let task = session.dataTask(with: request) { data, response, error in
            var vectors: [[Float]]?
            if let error = error as? URLError, [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost].contains(error.code) {
                OllamaCatalog.shared.markDown(base: base)
            }
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = json["embeddings"] as? [[NSNumber]], rows.count == count {
                vectors = rows.map { Self.normalized($0.map(\.floatValue)) }
            }
            box.set(vectors)
            completion?(vectors)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.25) == .timedOut {
            if completion == nil { task.cancel() }
            return nil
        }
        return box.get()
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

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [[Float]]?
        func set(_ v: [[Float]]?) { lock.withLock { value = v } }
        func get() -> [[Float]]? { lock.withLock { value } }
    }
}

/// Which models Ollama has, asked at most every 30 seconds. Remembers when it was down so
/// keystrokes don't each wait on a refused connection.
final class OllamaCatalog: @unchecked Sendable {
    static let shared = OllamaCatalog()
    private let lock = NSLock()
    private var entries: [String: (models: [String]?, checked: Date)] = [:]
    static let interval: TimeInterval = 30

    func cachedModels(base: URL) -> [String]? {
        lock.withLock { entries[Self.key(base)]?.models }
    }

    func isDown(base: URL) -> Bool {
        lock.withLock {
            guard let e = entries[Self.key(base)] else { return false }
            return e.models == nil && Date().timeIntervalSince(e.checked) < Self.interval
        }
    }

    func markDown(base: URL) { lock.withLock { entries[Self.key(base)] = (nil, Date()) } }

    /// Installed model tags, or nil when Ollama isn't answering.
    func models(base: URL) -> [String]? {
        let key = Self.key(base)
        if let e = lock.withLock({ entries[key] }), Date().timeIntervalSince(e.checked) < Self.interval { return e.models }
        var tags = URLComponents(url: base, resolvingAgainstBaseURL: false)
        tags?.path = "/api/tags"
        guard let url = tags?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var names: [String]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String ?? $0["model"] as? String }
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        let result = names
        lock.withLock { entries[key] = (result, Date()) }
        return result
    }

    private static func key(_ url: URL) -> String { (url.host ?? "") + ":" + String(url.port ?? 0) }
}

/// Apple's contextual embeddings, mean-pooled into one vector per text. Latin and CJK
/// scripts use different models whose spaces don't align, so a vector is the two halves
/// side by side: [Latin 512 | CJK 512], each weighted by how much of the text is in it.
/// On-device and always there once the assets are, but weaker than the Ollama models.
final class AppleEmbedder: @unchecked Sendable {
    static let shared = AppleEmbedder()
    private let lock = NSLock()
    private var latin: NLContextualEmbedding?
    private var cjk: NLContextualEmbedding?
    private var loaded = false
    private var requested = false
    static let half = 512

    var isAvailable: Bool {
        lock.withLock {
            if !loaded { load() }
            return latin != nil || cjk != nil
        }
    }

    private func load() {
        loaded = true
        for script in [NLScript.latin, NLScript.simplifiedChinese] {
            guard let model = NLContextualEmbedding(script: script), model.dimension == Self.half else { continue }
            if !model.hasAvailableAssets {
                if !requested { model.requestAssets { _, _ in } }
                continue
            }
            guard (try? model.load()) != nil else { continue }
            if script == .latin { latin = model } else { cjk = model }
        }
        requested = true
    }

    func embed(_ texts: [String]) -> [[Float]]? {
        lock.withLock {
            if !loaded { load() }
            guard latin != nil || cjk != nil else { return nil }
            return texts.map(vector)
        }
    }

    private func vector(_ text: String) -> [Float] {
        var han = 0, letters = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: han += 1
            default: if CharacterSet.letters.contains(s) { letters += 1 }
            }
        }
        // A Han character carries about as much as a short word.
        let cjkWeight = Float(han) * 4, latinWeight = Float(letters)
        var out = [Float](repeating: 0, count: Self.half * 2)
        if latinWeight > 0, let latin, let v = pooled(latin, text, language: .english) {
            let w = latinWeight / (latinWeight + cjkWeight)
            for i in 0..<Self.half { out[i] = v[i] * w }
        }
        if cjkWeight > 0, let cjk, let v = pooled(cjk, text, language: .simplifiedChinese) {
            let w = cjkWeight / (latinWeight + cjkWeight)
            for i in 0..<Self.half { out[Self.half + i] = v[i] * w }
        }
        return Embedder.normalized(out)
    }

    private func pooled(_ model: NLContextualEmbedding, _ text: String, language: NLLanguage) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var n = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            n += 1
            return true
        }
        guard n > 0 else { return nil }
        return Embedder.normalized(sum.map { Float($0 / Double(n)) })
    }
}

/// Stored vectors: a Float32 scale, then one Int8 per dimension. A quarter the size of
/// Float32 and indistinguishable for ranking (cosine error about 0.002).
enum VectorCodec {
    static func encode(_ v: [Float]) -> Data {
        var maxAbs: Float = 0
        vDSP_maxmgv(v, 1, &maxAbs, vDSP_Length(v.count))
        let scale = maxAbs > 0 ? maxAbs / 127 : 1
        var data = Data(count: 4 + v.count)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: scale.bitPattern.littleEndian, as: UInt32.self)
            let codes = raw.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int8.self)
            for i in 0..<v.count { codes[i] = Int8(max(-127, min(127, (v[i] / scale).rounded()))) }
        }
        return data
    }

    /// Unit-length floats, optionally truncated to the first `dimensions` (Matryoshka).
    static func decode(_ data: Data, dimensions: Int? = nil) -> [Float]? {
        guard data.count > 4 else { return nil }
        let dim = data.count - 4
        return data.withUnsafeBytes { raw -> [Float] in
            let codes = raw.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int8.self)
            let n = min(dim, dimensions ?? dim)
            var out = [Float](repeating: 0, count: n)
            vDSP_vflt8(codes, 1, &out, 1, vDSP_Length(n))
            return Embedder.normalized(out)
        }
    }

    static func dimensions(_ data: Data) -> Int { max(0, data.count - 4) }
}

/// Every stored section vector in one contiguous Float32 matrix, for brute-force cosine.
/// Kept for tests and small callers; search uses `VectorIndex`.
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
    var cancelled = false
    var scheduled = false
    var running = false
    /// `IndexStore` clears this after every write; the semantic index takes that as a hint
    /// to look for new vectors before the next query.
    var matrix: VectorMatrix? {
        didSet {
            guard matrix == nil else { return }
            dirty = true
            if let onDirty { DispatchQueue.global(qos: .background).async(execute: onDirty) }
        }
    }
    var dirty = true
    /// Set on the writer once background embedding is on: every index write (a new thought,
    /// a changed file) queues an embedding pass, which finds the new text quickly.
    var onDirty: (@Sendable () -> Void)?
    /// Recent query vectors (legacy; queries now share `SemanticRuntime.queries`).
    var queries: [String: [Float]] = [:]
    /// When Ollama last failed; semantic search stays off for a while after.
    var downSince: Date?
    let queue = DispatchQueue(label: "flamingo.embeddings", qos: .background)
    var embedder = Embedder()
    var titler = Titler()
    /// The in-memory vector indexes this store reads, shared with other stores on the same file.
    var indexes: [String: VectorIndex] = [:]
    /// Whether the semantic tables exist (checked once per store).
    var schemaReady: Bool?
    /// The model the last embedding pass used.
    var activeModel: String?
    /// Per model: the largest section rowid a finished pass had seen, and when the last full
    /// sweep finished. Between sweeps a pass only looks above the watermark.
    var watermark: [String: Int] = [:]
    var lastSweep: [String: Date] = [:]
    /// `similarFiles` answers by file, limit and file-vector generation.
    var similar: [String: [(file: FileRef, score: Double, passage: String?)]] = [:]
}

/// Reciprocal rank fusion: each list contributes weight / (k + rank) for the items it has.
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
