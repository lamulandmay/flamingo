import XCTest
@testable import FlamingoCore

/// The fast paths added for large vaults must answer exactly what the general code does.
final class PerformancePathTests: XCTestCase {
    private let corpus = [
        "file10.txt", "file2.txt", "File1.txt", "file1.txt", "FILE01.txt", "a.md", "B.md", "_notes", "-dash", ".hidden",
        "éclair.md", "eclair.md", "Éclair.MD", "zebra", "Zürich 2", "Zürich 10", "日本語.txt", "中文", "ﾃｽﾄ", "テスト",
        "2024-01-02 report", "2024-1-2 report", "report (copy).pdf", "report(copy).pdf", "report copy.pdf", "~$lock.docx",
        "Ⅻ chapter", "x 9", "x 09", "x 9a", "x9", "😀 smile", "a.b.c", "a b", "a  b", "a\tb", "İstanbul", "istanbul", "ß", "ss",
    ]

    func testFinderOrderMatchesLocalizedStandardCompare() {
        var names = corpus
        for i in 0..<200 { names.append("note-\(i % 37)-\(["Alpha", "beta", "Gamma", "délta"][i % 4])-\(i).md") }
        for seed in 0..<5 {
            var g = SystemRandomNumberGenerator()
            let shuffled = seed == 0 ? names : names.shuffled(using: &g)
            XCTAssertEqual(FinderOrder.sorted(shuffled), shuffled.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        for a in corpus { for b in corpus {
            XCTAssertEqual(FinderOrder.precedes(a, b), a.localizedStandardCompare(b) == .orderedAscending, "\(a) vs \(b)")
        } }
    }

    func testOneShotResolveMatchesTheFullResolver() throws {
        let tv = try TempVault()
        let paths = [
            "decks/q3.pptx", "decks/Q3.pptx", "old/q3.pptx", "q3.md", "notes/q3", "notes/.q3", "notes/q3.final.pptx",
            "Café/menu.md", "Cafe\u{301}/menu2.md", "x/back\\slash.md", "deep/a/b/c/Target File.docx", "target file.txt",
            "KELVIN/\u{212A}elvin.md", "i/İstanbul.md", "日本/会議.md", "a/README", "b/readme.md", "c/ReadMe.MD",
        ]
        let candidates = paths.map(FileRef.init(relativePath:))
        let targets = paths + paths.map { $0.uppercased() } + paths.map { ($0 as NSString).lastPathComponent }
            + paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            + ["q3", "Q3", "q3.PPTX", "./decks/q3.pptx", "/decks/q3.pptx", "decks/q3", "[[q3#slide 2|alias]]", "menu", "MENU.MD",
               "kelvin", "\u{212A}elvin", "istanbul", "会議", "readme", "README.md", "target file", "Target File", "", "missing",
               "renamed/q3.pptx", "renamed/q3", "renamedfolder/Target File.docx", "gone.md"]
        let source = FileRef(relativePath: "old/x.md")
        func check(_ aliases: [String: String]) {
            let full = Wikilink.Resolver(candidates: candidates, aliases: aliases)
            for t in targets {
                XCTAssertEqual(Wikilink.resolveOnce(t, from: nil, aliases: aliases, candidates: candidates), full.resolve(t), "target \(t)")
                XCTAssertEqual(Wikilink.resolveOnce(t, from: source, aliases: aliases, candidates: candidates), full.resolve(t, from: source), "target \(t) near source")
            }
        }
        check([:])
        check(["renamed": "decks", "renamedfolder": "deep/a/b/c", "gone.md": "q3.md"])
        // The public entry points read the vault's alias file.
        XCTAssertEqual(Wikilink.resolve("q3.pptx", in: tv.vault, candidates: candidates), Wikilink.Resolver(candidates: candidates).resolve("q3.pptx"))
    }

    func testIgnoreBasenameAndAsciiSuffixMatching() {
        XCTAssertEqual(IgnoreRules.basename(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(IgnoreRules.basename(of: "a/b/"), "b")
        XCTAssertEqual(IgnoreRules.basename(of: "c"), "c")
        XCTAssertEqual(IgnoreRules.basename(of: "///"), "///")
        XCTAssertEqual(IgnoreRules.basename(of: "日本/会議.md"), "会議.md")
        let rules = IgnoreRules(text: "*.app\n*.café\nbuild/\n**/Library/Caches\n!keep.app")
        XCTAssertTrue(rules.isIgnored("x/Tool.app", isDirectory: true))
        XCTAssertFalse(rules.isIgnored("x/keep.app", isDirectory: true))
        XCTAssertTrue(rules.isIgnored("menu.café", isDirectory: false))
        XCTAssertTrue(rules.isIgnored("menu.cafe\u{301}", isDirectory: false), "non-ASCII suffixes keep Unicode equivalence")
        XCTAssertFalse(rules.isIgnored("app", isDirectory: false))
        XCTAssertTrue(rules.isIgnored("a//build/x.txt", isDirectory: false), "empty components are skipped for ancestors")
        XCTAssertTrue(rules.isIgnored("Users/me/Library/Caches/x", isDirectory: false))
    }

    func testSidecarListingSkipsNamesWithoutAnExtension() throws {
        let tv = try TempVault()
        let store = SidecarStore(vault: tv.vault)
        let notes = tv.vault.notesDir
        try FileManager.default.createDirectory(at: notes.appendingPathComponent(".hidden/deep"), withIntermediateDirectories: true)
        for name in [".md", "..md", "a.md", ".hidden/deep/b.txt.md", "c.MD", "d.markdown"] {
            try "x".write(to: notes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try store.sidecarRefs().map(\.relativePath), [".hidden/deep/b.txt", "a"])
    }

    func testScannerReturnsVaultRelativePathsUnderASymlinkedRoot() throws {
        // /tmp and /var are symlinks into /private; the vault root is stored standardized.
        let tv = try TempVault()
        try tv.file("x/y.txt")
        try tv.file("z.md")
        let private_ = Vault(root: URL(fileURLWithPath: tv.root.resolvingSymlinksInPath().path))
        XCTAssertEqual(VaultScanner.files(in: private_, ignore: .empty).map(\.relativePath), ["x/y.txt", "z.md"])
        XCTAssertEqual(VaultScanner.files(in: tv.vault, ignore: .empty).map(\.relativePath), ["x/y.txt", "z.md"])
    }

    func testFileNamesMatchNSStringAndAreNative() {
        let paths = corpus + corpus.map { "dir/" + $0 } + [
            "a.txt", ".bashrc", "a.", "a..b", "dir.d/file", "a.tar.gz", "a b.TXT", ".", "..", "a/.hidden", "...", "a/b/", "a//b",
            "/", "", "x/y.Z", "foo.some thing", "a/b.c/", "a/b..", "a/.b.c", "a/..b", "a.b/.", "file.tar.", "x.\u{301}", "noext/",
            "a.TxT", "a.b\tc", "~/x.y", "x.ÄÖ", "//", "a///", ".x.y", "..x", "a.tar-gz", "a.b_c", "a.b+c", "a.b ", "a. b",
            "x.7z", "x.123", ".._x", ".a..b", "a.B-C_1", " .x", "Résumé.PDF", "日本語.テキスト", "Cafe\u{301}/Menu.MD",
        ]
        for path in paths {
            let ref = FileRef(relativePath: path), ns = path as NSString
            XCTAssertEqual(ref.name, ns.lastPathComponent, path)
            XCTAssertEqual(ref.ext, ns.pathExtension.lowercased(), path)
            // Bridged strings compare through normalization; graph names must not be bridged.
            XCTAssertTrue(ref.name.isContiguousUTF8, path)
            XCTAssertTrue(ref.ext.isContiguousUTF8, path)
        }
    }

    func testFolderCatalogMatchesTheSplittingOne() {
        var g = SystemRandomNumberGenerator()
        let parts = ["a", "b", "Résumé", "Cafe\u{301}", "日本", ".hidden", "x.y", "..", ".", "", "_inbox", "_web", ".flamingo", "-dash", "!bang", "a b"]
        func randomID() -> String {
            let depth = Int.random(in: 1...4, using: &g)
            var id = (0..<depth).map { _ in parts.randomElement(using: &g)! }.joined(separator: "/")
            switch Int.random(in: 0..<10, using: &g) {
            case 0: id += "/"
            case 1: id = "/" + id
            case 2: id = "/"
            default: id += "/f\(Int.random(in: 0..<5, using: &g)).txt"
            }
            return id
        }
        func node(_ id: String) -> Graph.Node {
            Graph.Node(id: id, name: FileRef(relativePath: id).name, ext: "", commentCount: Int.random(in: 0...1, using: &g))
        }
        for _ in 0..<200 {
            let nodes = (0..<Int.random(in: 0...30, using: &g)).map { _ in node(randomID()) }
            let sources = Bool.random(using: &g) ? nil : (0..<Int.random(in: 0...40, using: &g)).map { _ in node(randomID()) }
            var edges = (0..<Int.random(in: 0...10, using: &g)).map { _ in
                Graph.Edge(source: randomID(), target: randomID(), kind: [.folder, .link, .related].randomElement(using: &g)!)
            }
            if let a = nodes.first, let b = nodes.last { edges.append(Graph.Edge(source: a.id, target: b.id, kind: .folder)) }
            let graph = Graph(nodes: nodes, edges: edges)
            XCTAssertEqual(GraphFolders.addingAncestors(to: graph, from: sources), SplittingFolders.addingAncestors(to: graph, from: sources))
        }
    }
}

/// `GraphFolders` as it was before it read paths as UTF-8: split into components, joined back.
private enum SplittingFolders {
    static func addingAncestors(to graph: Graph, from sourceNodes: [Graph.Node]? = nil) -> Graph {
        var nodes = graph.nodes
        var present = Set(nodes.map(\.id))
        var folders = Set<String>()
        var sourceFolders: [String: Graph.Node] = [:]
        func collect(_ node: Graph.Node) {
            guard let components = pathComponents(node.id) else { return }
            folders.insert("/")
            let isFolder = node.id.hasSuffix("/")
            if isFolder { sourceFolders[node.id] = node }
            let ancestorCount = components.count - (isFolder ? 0 : 1)
            var path = ""
            for component in components.prefix(ancestorCount) {
                path += component + "/"
                folders.insert(path)
            }
        }
        for node in graph.nodes { collect(node) }
        if let sourceNodes { for node in sourceNodes { collect(node) } }
        for id in folders.sorted() where present.insert(id).inserted {
            nodes.append(sourceFolders[id] ?? Graph.Node(
                id: id, name: id == "/" ? "/" : (String(id.dropLast()) as NSString).lastPathComponent, ext: ""))
        }
        var edges: [Graph.Edge] = []
        var containment = Set<[String]>()
        for edge in graph.edges {
            if edge.kind == .folder {
                guard present.contains(edge.source), present.contains(edge.target),
                      containment.insert([edge.source, edge.target]).inserted else { continue }
            }
            edges.append(edge)
        }
        for node in nodes {
            guard let components = pathComponents(node.id), !components.isEmpty else { continue }
            let parent = components.count == 1 ? "/" : components.dropLast().joined(separator: "/") + "/"
            guard present.contains(parent), containment.insert([parent, node.id]).inserted else { continue }
            edges.append(Graph.Edge(source: parent, target: node.id, kind: .folder))
        }
        return Graph(nodes: nodes, edges: edges)
    }

    static func pathComponents(_ id: String) -> [String]? {
        if id == "/" { return [] }
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\0") else { return nil }
        let path = id.hasSuffix("/") ? String(id.dropLast()) : id
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, first != FileRef.inboxDirectory, first != FileRef.webDirectory, first != ".flamingo",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }
}
