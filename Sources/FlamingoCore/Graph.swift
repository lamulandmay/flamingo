import Foundation

/// Serialized to `<vault>/.flamingo/graph.json`. Built by FlamingoIndex, drawn by FlamingoGraph.
public struct Graph: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable, Identifiable {
        public var id: String          // relative path
        public var name: String
        public var ext: String
        public var commentCount: Int
        public init(id: String, name: String, ext: String, commentCount: Int = 0) {
            self.id = id; self.name = name; self.ext = ext; self.commentCount = commentCount
        }
    }
    public struct Edge: Codable, Sendable, Equatable {
        /// `folder` edges join a folder node (id ends in `/`) to its direct children.
        /// `mention` edges are discovered: a file's text names another file.
        /// `related` edges are discovered too: the two files say similar things.
        ///
        /// Two families. Explicit edges are ones a person made: a `link` written in a thought
        /// or note, a `manual` connection. Inferred edges are ones Flamingo noticed
        /// (`mention`, `trail`, `related`) and stay suggestions until accepted.
        public enum Kind: String, Codable, Sendable { case link, trail, folder, mention, manual, related

            /// A person made this connection, by linking or connecting.
            public var isExplicit: Bool { self == .link || self == .manual }
            /// Flamingo noticed this connection; it can be accepted or dismissed.
            public var isInferred: Bool { self == .mention || self == .trail || self == .related }
        }
        public var source: String
        public var target: String
        public var kind: Kind
        public var weight: Double
        public init(source: String, target: String, kind: Kind, weight: Double = 1) {
            self.source = source; self.target = target; self.kind = kind; self.weight = weight
        }
    }
    public var nodes: [Node]
    public var edges: [Edge]
    public init(nodes: [Node] = [], edges: [Edge] = []) { self.nodes = nodes; self.edges = edges }
}
