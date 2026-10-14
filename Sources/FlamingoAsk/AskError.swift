import Foundation

/// Why a question didn't get an answer. `errorDescription` is the one tertiary line the view shows.
public enum AskError: Error, Equatable, LocalizedError {
    case noKey
    case keyRejected
    case keychain(OSStatus)
    case rateLimited
    case overloaded
    case refused
    case offline
    case api(status: Int, message: String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "No API key"
        case .keyRejected: return "API key rejected"
        case .keychain(let status): return "Keychain error \(status)"
        case .rateLimited: return "Rate limited"
        case .overloaded: return "Claude is overloaded"
        case .refused: return "Declined"
        case .offline: return "Offline"
        case .api(let status, let message): return message.isEmpty ? "HTTP \(status)" : message
        case .stream(let message): return message
        }
    }

    /// Maps an HTTP status and the API's `{"error": {"type", "message"}}` body.
    static func http(_ status: Int, body: Data) -> AskError {
        let error = (try? JSON.decode(body))?["error"]
        let type = error?["type"]?.string ?? ""
        let message = (error?["message"]?.string ?? "").split(separator: "\n").first.map(String.init) ?? ""
        switch (status, type) {
        case (401, _), (_, "authentication_error"): return .keyRejected
        case (429, _), (_, "rate_limit_error"): return .rateLimited
        case (529, _), (_, "overloaded_error"): return .overloaded
        default: return .api(status: status, message: message)
        }
    }

    /// Worth retrying before any output has arrived.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .offline: return true
        case .api(let status, _): return status >= 500
        default: return false
        }
    }
}
