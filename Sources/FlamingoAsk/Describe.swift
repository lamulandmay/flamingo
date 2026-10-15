import Foundation
import ImageIO
import UniformTypeIdentifiers
import FlamingoCore

extension AskEngine {
    /// Looks at an image (or a rendered slide) with the local 27B and leaves what it saw on
    /// the file as a comment anchored `(region full)`: a thought the model left, nothing more.
    /// On demand only (the palette's "Describe Image"); never part of indexing.
    /// Returns the comment as written to the sidecar.
    @discardableResult
    public func describe(image: Data, of file: FileRef,
                         anchor: FileAnchor = FileAnchor(kind: .region, value: "full")) async throws -> Comment {
        guard let jpeg = Self.jpeg(image, maxPixels: 1024) else { throw AskError.stream("Not an image") }
        let url = try await llama { }
        let endpoint = ChatEndpoint(baseURL: url, model: LlamaServer.modelName, kind: .llama)
        let body = Prompt.describeBody(endpoint, jpeg: jpeg, name: file.name)
        let text = try await chat.send(body, to: endpoint) { _ in }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AskError.stream("No description") }
        let comment = Comment(anchor: anchor, text: text)
        let sidecars = SidecarStore(vault: index.vault)
        try sidecars.append(comment, to: file)
        try? index.update([file])   // the comment is searchable at once, without waiting on the watcher
        return (try? sidecars.comments(for: file))?.last { $0.text == text } ?? comment
    }

    /// `describe(image:of:)` for an image file in the vault.
    @discardableResult
    public func describe(_ file: FileRef) async throws -> Comment {
        let data = try Data(contentsOf: index.vault.url(for: file))
        return try await describe(image: data, of: file)
    }

    /// Re-encoded as JPEG, longest side at most `maxPixels`, so the projector's token budget holds.
    static func jpeg(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension Prompt {
    static let describe = """
    Describe this image in two or three plain sentences for someone searching their own files \
    later: what it shows, and any text, numbers or names in it that matter. No preamble.
    """

    static func describeBody(_ endpoint: ChatEndpoint, jpeg: Data, name: String) -> JSON {
        [
            "model": .string(endpoint.model),
            "stream": true,
            "max_tokens": 400,
            "temperature": .double(0.7),
            "top_p": .double(0.8),
            "top_k": 20,
            "presence_penalty": .double(1.5),
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64," + jpeg.base64EncodedString())]],
                ["type": "text", "text": .string("File: \(name)\n\n" + describe)],
            ]]],
        ]
    }
}
