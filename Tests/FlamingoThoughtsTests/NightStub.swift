import Foundation
import XCTest
import FlamingoAsk

/// A network that serves loopback from a script and refuses everything else, for the tests that
/// run a real `AskEngine` under the night shift.
final class NightStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _urls: [URL] = []
    nonisolated(unsafe) private static var _handler: (@Sendable (URL, Data) -> Data?)?

    static var urls: [URL] { lock.withLock { _urls } }
    static var violations: [URL] { urls.filter { !LocalEndpoint.isLoopback($0) } }
    static func reset(_ handler: (@Sendable (URL, Data) -> Data?)?) { lock.withLock { _urls = []; _handler = handler } }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NightStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let handler = Self.lock.withLock { () -> (@Sendable (URL, Data) -> Data?)? in Self._urls.append(url); return Self._handler }
        guard LocalEndpoint.isLoopback(url), let reply = handler?(url, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(LocalEndpoint.isLoopback(url) ? .cannotConnectToHost : .notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// An OpenAI-style streamed reply carrying `text`.
    static func chat(_ text: String) -> Data {
        let chunk = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text]]]])
        let events = [String(decoding: chunk, as: UTF8.self), #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "[DONE]"]
        return Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }
}
