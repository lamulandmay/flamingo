import Foundation
import Network

/// Who answers. `auto` is Claude when there's a key and a network, else the local 27B.
public enum AskProvider: String, CaseIterable, Sendable {
    case auto
    case claude
    /// Qwen 27B under `llama-server`, started on demand.
    case llama
    /// A small model under Ollama.
    case ollama

    static let defaultsKey = "FlamingoAskProvider"
    public static let didChange = Notification.Name("FlamingoAskProviderDidChange")

    /// The stored choice. The palette's "Ask: Use Local Model" / "Ask: Use Claude" set it.
    public static var preferred: AskProvider {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AskProvider.init) ?? .auto }
        set {
            UserDefaults.standard.set(newValue == .auto ? nil : newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The Ollama model Ask uses when the provider is `ollama`.
    public static var ollamaModel: String {
        UserDefaults.standard.string(forKey: "FlamingoOllamaModel") ?? "gemma3:4b"
    }
}

/// An OpenAI-compatible endpoint and the model to ask there.
struct ChatEndpoint: Sendable, Equatable {
    var baseURL: URL
    var model: String
    var kind: AskProvider

    static let ollama = URL(string: "http://127.0.0.1:11434/v1")!
}

/// Whether the Mac has a route out. Starts watching on first use.
final class Reachability: @unchecked Sendable {
    static let shared = Reachability()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var status: NWPath.Status?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.lock.withLock { self?.status = path.status } }
        monitor.start(queue: DispatchQueue(label: "flamingo.reachability"))
    }

    /// Unknown counts as online: the request itself will say otherwise.
    var isOnline: Bool { lock.withLock { status } != .unsatisfied }
}
