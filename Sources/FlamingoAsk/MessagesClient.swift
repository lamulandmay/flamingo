import Foundation

/// Server-sent events, fed one line at a time. A blank line ends an event.
struct SSEParser {
    struct Event: Equatable {
        var name: String?
        var data: String
    }

    private var name: String?
    private var data: [String] = []

    mutating func feed(_ line: String) -> Event? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring = ""
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    mutating func flush() -> Event? {
        defer { name = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return Event(name: name, data: data.joined(separator: "\n"))
    }
}

/// One assistant message assembled from Messages API stream events. Content blocks are kept
/// as the API sent them, deltas folded in, so they can go back verbatim in a tool loop.
struct StreamedMessage: Equatable {
    var model: String?
    var content: [JSON] = []
    var stopReason: String?
    var stopDetails: JSON?
    /// `tool_use` inputs that weren't valid JSON objects, by block index, as received.
    var invalidInputs: [Int: String] = [:]
    var finished = false

    private var partialInputs: [Int: String] = [:]

    var text: String {
        content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
    }

    /// Applies one event and returns any answer text it carried.
    mutating func apply(_ event: JSON) throws -> String? {
        switch event["type"]?.string {
        case "message_start":
            model = event["message"]?["model"]?.string
        case "content_block_start":
            guard let i = event["index"]?.int, i >= 0, let block = event["content_block"] else { return nil }
            while content.count <= i { content.append(.null) }
            content[i] = block
            if block["type"]?.string == "text", let t = block["text"]?.string, !t.isEmpty { return t }
        case "content_block_delta":
            guard let i = event["index"]?.int, content.indices.contains(i), let delta = event["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                let t = delta["text"]?.string ?? ""
                append(t, to: "text", at: i)
                return t.isEmpty ? nil : t
            case "thinking_delta": append(delta["thinking"]?.string ?? "", to: "thinking", at: i)
            case "signature_delta": append(delta["signature"]?.string ?? "", to: "signature", at: i)
            case "input_json_delta": partialInputs[i, default: ""] += delta["partial_json"]?.string ?? ""
            default: break
            }
        case "content_block_stop":
            guard let i = event["index"]?.int, content.indices.contains(i),
                  content[i]["type"]?.string == "tool_use" else { return nil }
            let raw = partialInputs.removeValue(forKey: i) ?? ""
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if content[i]["input"] == nil { content[i]["input"] = [:] }
            } else if let parsed = try? JSON.decode(Data(raw.utf8)), parsed.object != nil {
                content[i]["input"] = parsed
            } else {
                invalidInputs[i] = raw
                content[i]["input"] = [:]
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let details = event["delta"]?["stop_details"], details != .null { stopDetails = details }
        case "message_stop":
            finished = true
        case "error":
            let type = event["error"]?["type"]?.string
            let message = event["error"]?["message"]?.string ?? "Stream error"
            switch type {
            case "overloaded_error": throw AskError.overloaded
            case "rate_limit_error": throw AskError.rateLimited
            default: throw AskError.stream(message)
            }
        default:
            break   // ping, and event types added later
        }
        return nil
    }

    private mutating func append(_ s: String, to field: String, at i: Int) {
        content[i][field] = .string((content[i][field]?.string ?? "") + s)
    }
}

/// `POST /v1/messages` with `stream: true`, over `URLSession`. Swift has no official SDK, and
/// Flamingo takes no dependencies.
struct MessagesClient: Sendable {
    var session: URLSession = .shared
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    var maxRetries = 2
    /// Seconds before the first retry; doubles each time.
    var retryDelay: Double = 1

    /// Streams one assistant message. Retries rate limits, overloads, 5xx and dropped
    /// connections, but only while nothing has been shown yet.
    func send(_ body: JSON, key: String, betas: [String],
              onText: @escaping @Sendable (String) -> Void) async throws -> StreamedMessage {
        var attempt = 0
        while true {
            var shown = false
            do {
                return try await once(body, key: key, betas: betas, shown: &shown, onText: onText)
            } catch let error as AskError where error.isTransient && !shown && attempt < maxRetries {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * pow(2, Double(attempt)) * 1e9))
                attempt += 1
            }
        }
    }

    private func once(_ body: JSON, key: String, betas: [String], shown: inout Bool,
                      onText: @Sendable (String) -> Void) async throws -> StreamedMessage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try body.encoded()

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AskError.stream("No response") }
            guard http.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw AskError.http(http.statusCode, body: data)
            }

            var message = StreamedMessage()
            var parser = SSEParser()
            var line: [UInt8] = []
            func handle(_ event: SSEParser.Event) throws {
                guard let json = try? JSON.decode(Data(event.data.utf8)) else { return }
                if let text = try message.apply(json) { shown = true; onText(text) }
            }
            for try await byte in bytes {
                if byte == 0x0A {
                    if line.last == 0x0D { line.removeLast() }
                    if let event = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(event) }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, let event = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(event) }
            if let event = parser.flush() { try handle(event) }
            guard message.finished || message.stopReason != nil else { throw AskError.offline }
            return message
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AskError.offline
        }
    }
}
