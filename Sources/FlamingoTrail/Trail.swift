import Foundation
import FlamingoCore

/// One thing that happened. Appended to `<vault>/.flamingo/trail.jsonl`.
public struct TrailEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case opened, commented, searched, linked }
    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var file: FileRef?
    public var anchor: FileAnchor?
    public var text: String?       // comment text or search query
    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind, file: FileRef? = nil, anchor: FileAnchor? = nil, text: String? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.file = file; self.anchor = anchor; self.text = text
    }
}

/// A chain of events that belong together in time. Plan 07 defines the clustering.
public struct TrailSession: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var events: [TrailEvent]
    public var files: [FileRef]
    public init(id: UUID = UUID(), start: Date, end: Date, events: [TrailEvent], files: [FileRef]) {
        self.id = id; self.start = start; self.end = end; self.events = events; self.files = files
    }
}

/// Records and reads the trail. Plan 07 owns.
public final class TrailStore: @unchecked Sendable {
    public let vault: Vault
    public init(vault: Vault) { self.vault = vault }
    public func record(_ event: TrailEvent) { /* TODO(plan 07): append jsonl */ }
    public func events(since: Date? = nil) throws -> [TrailEvent] { [] }
    public func sessions() throws -> [TrailSession] { [] }
    /// Edges to merge into the graph: files touched within the same session.
    public func edges() throws -> [Graph.Edge] { [] }
}
