import Foundation

/// One blocking HTTP call to a local Ollama server, shared by titling, embedding and the model
/// catalog. (FlamingoAsk's chat has its own streaming client.)
///
/// The reply is turned into its result on URLSession's queue and handed over through a locked
/// box, so a callback that lands after the caller stopped waiting never races it. The wait is
/// sliced into quarter seconds so `isCancelled` can end a long one (a model still loading)
/// early; the request's own `timeoutInterval` bounds how long the server may take.
enum OllamaHTTP {
    struct Reply: Sendable {
        let data: Data?
        let status: Int?
        let error: URLError?

        /// The body as a JSON object, for a 200 reply.
        var json: [String: Any]? {
            guard status == 200, let data else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// `base` with its path replaced, e.g. `/api/tags`.
    static func endpoint(_ base: URL, path: String) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url
    }

    /// A JSON POST to `url`.
    static func post(_ url: URL, body: [String: Any], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends `request` and waits at most `wait` seconds for `transform(reply)`. Nil when the wait
    /// ran out or `isCancelled` said stop. The request is then cancelled, unless `outlive` is set:
    /// it keeps going (to finish loading a model) and `completion` still gets its result.
    static func send<T: Sendable>(_ request: URLRequest, session: URLSession = .shared, wait: TimeInterval,
                                  isCancelled: (() -> Bool)? = nil, outlive: Bool = false,
                                  transform: @escaping @Sendable (Reply) -> T,
                                  completion: (@Sendable (T) -> Void)? = nil) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        let task = session.dataTask(with: request) { data, response, error in
            let value = transform(Reply(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error as? URLError))
            box.set(value)
            completion?(value)
            done.signal()
        }
        task.resume()
        let deadline = DispatchTime.now() + max(0, wait)
        while true {
            if done.wait(timeout: min(deadline, .now() + 0.25)) == .success { return box.get() }
            if DispatchTime.now() >= deadline || isCancelled?() == true {
                if !outlive { task.cancel() }
                return nil
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.withLock { value = v } }
        func get() -> T? { lock.withLock { value } }
    }
}
