import Foundation
import FlamingoCore
import FlamingoExtract

public struct SearchHit: Identifiable, Sendable, Equatable {
    public var id: String { file.relativePath + (anchor?.rendered ?? "") }
    public var file: FileRef
    public var anchor: FileAnchor?
    public var snippet: String   // with match ranges marked as «…»
    public var score: Double
    public init(file: FileRef, anchor: FileAnchor? = nil, snippet: String, score: Double) {
        self.file = file; self.anchor = anchor; self.snippet = snippet; self.score = score
    }
}

/// SQLite + FTS5 at `<vault>/.flamingo/index.sqlite`. Plan 05 owns.
public final class IndexStore: @unchecked Sendable {
    public let vault: Vault
    public init(vault: Vault) throws { self.vault = vault /* TODO(plan 05): open db, migrate */ }

    /// Full reindex. Reports progress 0...1.
    public func reindex(progress: ((Double) -> Void)? = nil) throws { /* TODO(plan 05) */ }
    /// Incremental: re-extract these files only.
    public func update(_ refs: [FileRef]) throws { /* TODO(plan 05) */ }
    public func remove(_ refs: [FileRef]) throws { /* TODO(plan 05) */ }

    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] { [] }
    public func sections(of ref: FileRef) throws -> [Section] { [] }
    public func text(of ref: FileRef) throws -> String? { nil }

    /// Builds the link graph from sidecars (and trail edges if present) and writes graph.json.
    public func buildGraph(extraEdges: [Graph.Edge] = []) throws -> Graph { Graph(edges: extraEdges) }
}
