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
        public enum Kind: String, Codable, Sendable { case link, trail, folder }
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
