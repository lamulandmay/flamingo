import Foundation
@testable import FlamingoAsk

/// Stands in for api.anthropic.com. Queue replies, then inspect the requests that were made.
final class MockAPI: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var _requests: [(request: URLRequest, body: JSON)] = []

    static var requests: [(request: URLRequest, body: JSON)] { lock.withLock { _requests } }

    static func reset(_ replies: [Reply]) {
        lock.withLock { self.replies = replies; _requests = [] }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAPI.self]
        return URLSession(configuration: config)
    }

    static var client: MessagesClient {
        var c = MessagesClient()
        c.session = session
        c.retryDelay = 0
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let reply: Reply = Self.lock.withLock {
            Self._requests.append((request, (try? JSON.decode(data)) ?? .null))
            return Self.replies.isEmpty ? Reply(status: 500, body: Data()) : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Odd-sized chunks, so lines and UTF-8 sequences straddle reads.
        var i = 0
        while i < reply.body.count {
            let j = min(i + 13, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: i..<j))
            i = j
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Builds Messages API stream bodies.
enum SSE {
    static func body(_ events: [JSON]) -> Data {
        Data(events.map { e in
            "event: \(e["type"]?.string ?? "")\r\ndata: \(String(decoding: try! e.encoded(), as: UTF8.self))\r\n\r\n"
        }.joined().utf8)
    }

    static func reply(_ events: [JSON]) -> MockAPI.Reply { MockAPI.Reply(status: 200, body: body(events)) }

    static func error(_ status: Int, _ type: String, _ message: String) -> MockAPI.Reply {
        let json: JSON = ["type": "error", "error": ["type": .string(type), "message": .string(message)]]
        return MockAPI.Reply(status: status, body: try! json.encoded())
    }

    /// A complete message: optional thinking, the text in pieces, optional tool calls, a stop reason.
    static func message(thinking: Bool = true, text: [String], tools: [(id: String, input: String)] = [],
                        stop: String = "end_turn", model: String = "claude-sonnet-5-5") -> [JSON] {
        var events: [JSON] = [["type": "message_start", "message": ["id": "msg_1", "model": .string(model), "content": []]]]
        var i = 0
        if thinking {
            events += [
                ["type": "content_block_start", "index": .int(i), "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
                ["type": "content_block_delta", "index": .int(i), "delta": ["type": "thinking_delta", "thinking": ""]],
                ["type": "content_block_delta", "index": .int(i), "delta": ["type": "signature_delta", "signature": "sig-abc"]],
                ["type": "content_block_stop", "index": .int(i)],
            ]
            i += 1
        }
        if !text.isEmpty {
            events.append(["type": "content_block_start", "index": .int(i), "content_block": ["type": "text", "text": ""]])
            events.append(["type": "ping"])
            for t in text { events.append(["type": "content_block_delta", "index": .int(i), "delta": ["type": "text_delta", "text": .string(t)]]) }
            events.append(["type": "content_block_stop", "index": .int(i)])
            i += 1
        }
        for tool in tools {
            events.append(["type": "content_block_start", "index": .int(i),
                           "content_block": ["type": "tool_use", "id": .string(tool.id), "name": "search", "input": [:]]])
            let mid = tool.input.index(tool.input.startIndex, offsetBy: tool.input.count / 2)
            for part in [String(tool.input[..<mid]), String(tool.input[mid...])] {
                events.append(["type": "content_block_delta", "index": .int(i), "delta": ["type": "input_json_delta", "partial_json": .string(part)]])
            }
            events.append(["type": "content_block_stop", "index": .int(i)])
            i += 1
        }
        events.append(["type": "message_delta", "delta": ["stop_reason": .string(stop)], "usage": ["output_tokens": 12]])
        events.append(["type": "message_stop"])
        return events
    }
}
