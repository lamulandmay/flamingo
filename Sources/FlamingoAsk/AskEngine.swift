import Foundation
import FlamingoCore
import FlamingoIndex

public struct Citation: Sendable, Equatable, Identifiable {
    public var id: String { file.relativePath + (anchor?.rendered ?? "") }
    public var file: FileRef
    public var anchor: FileAnchor?
    public init(file: FileRef, anchor: FileAnchor? = nil) { self.file = file; self.anchor = anchor }
}

public struct Answer: Sendable, Equatable {
    public var text: String
    public var citations: [Citation]
    public init(text: String, citations: [Citation]) { self.text = text; self.citations = citations }
}

/// Retrieval over the index + a Claude call. Plan 09 owns.
public final class AskEngine: @unchecked Sendable {
    public let index: IndexStore
    public init(index: IndexStore) { self.index = index }
    public func ask(_ question: String) async throws -> Answer { Answer(text: "", citations: []) }
}
