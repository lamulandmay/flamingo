import Foundation
import FlamingoCore
import FlamingoIndex

// flamingo-index <vault> [--watch] [--search "query"]   Plan 05 owns.
let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    FileHandle.standardError.write("usage: flamingo-index <vault> [--watch] [--search query]\n".data(using: .utf8)!)
    exit(2)
}
let vault = Vault(root: URL(fileURLWithPath: path))
let store = try IndexStore(vault: vault)
try store.reindex { p in print("\r\(Int(p * 100))%", terminator: "") }
let graph = try store.buildGraph()
print("\n\(graph.nodes.count) files, \(graph.edges.count) links")
