import Foundation
import ModelIO
import FlamingoCore

/// 3D via ModelIO: one section per named node, anchored at its name path (`Robot/Arm/Hand`),
/// with vertex and face counts and material names for meshes. OBJ and STL are read directly:
/// ModelIO merges every `o`/`g` group of an OBJ into one mesh, losing the names worth anchoring
/// to, and loads every triangle of an STL only to name it after the binary header.
public struct ModelExtractor: Extractor {
    public static let extensions: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "abc"]
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        var scene = ModelScene(), header: [String] = []
        switch url.pathExtension.lowercased() {
        case "obj": try OBJScanner.scan(url, into: &scene)
        case "stl": header = try STLScanner.scan(url, into: &scene)
        // PLY has no material names; ModelIO invents "PLY Material".
        case let ext:
            if let helper = Self.helper, let read = try Self.readInHelper(url, executable: helper) { return read }
            try autoreleasepool { try Self.load(url, materials: ext != "ply", into: &scene) }
        }
        return scene.extracted(header: header)
    }

    // MARK: Helper process

    /// The app's own executable, set once at launch, to read ModelIO formats in a short-lived
    /// copy of itself (`helperFlag`). ModelIO loads Pixar's USD into whatever process opens an
    /// asset, and USD keeps a thread per core and one that wakes about 20 times a second for
    /// the rest of that process's life: an idle Flamingo that had indexed one `.usdz` never
    /// slept. A helper also keeps a file ModelIO crashes on from taking the app with it. Nil
    /// (tests, the CLI) reads in this process.
    nonisolated(unsafe) public static var helper: String?
    /// `<executable> --extract-model <file>` prints the file's `Extracted` as JSON and exits.
    public static let helperFlag = "--extract-model"

    /// The helper's side, called first thing in `main`: does nothing unless the arguments ask
    /// for a model read, in which case it reads, prints and exits without starting the app.
    public static func runHelperIfAsked(_ arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: helperFlag), i + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[i + 1])
        do {
            var scene = ModelScene()
            try autoreleasepool { try load(url, materials: url.pathExtension.lowercased() != "ply", into: &scene) }
            FileHandle.standardOutput.write(try JSONEncoder().encode(scene.extracted(header: [])))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }
    }

    /// Nil when the helper couldn't be started, so the caller reads in-process instead.
    static func readInHelper(_ url: URL, executable: String) throws -> Extracted? {
        guard let out = Subprocess.run(executable, [helperFlag, url.path], timeout: 60, maxOutput: 32 << 20) else { return nil }
        guard out.succeeded, let read = try? JSONDecoder().decode(Extracted.self, from: out.stdout) else {
            throw ExtractError.malformed(url.path)
        }
        return read
    }

    /// Textures are never loaded: ModelIO only reads them on `loadTextures()`.
    private static func load(_ url: URL, materials: Bool, into scene: inout ModelScene) throws {
        var error: NSError?
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false, error: &error)
        // A valid but empty stage loads with no objects and no error.
        if asset.count == 0, error != nil { throw ExtractError.malformed(url.path) }
        func walk(_ object: MDLObject, _ parent: [String]) {
            let named = !object.name.isEmpty
            let path = named ? parent + [object.name] : parent
            scene.add(path: named ? path : nil, mesh: (object as? MDLMesh).map { counts($0, materials: materials) })
            for child in object.children.objects { walk(child, path) }
        }
        for i in 0..<asset.count { walk(asset.object(at: i), []) }
    }

    /// Faces by each submesh's primitive. Imports are triangulated, so this is nearly always
    /// index count / 3; points and lines have no faces.
    private static func counts(_ mesh: MDLMesh, materials: Bool) -> ModelScene.Mesh {
        var faces = 0, names: [String] = []
        for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
            switch sub.geometryType {
            case .triangles: faces += sub.indexCount / 3
            case .triangleStrips: faces += max(sub.indexCount - 2, 0)
            case .quads: faces += sub.indexCount / 4
            case .variableTopology: faces += sub.topology?.faceCount ?? 0
            default: break
            }
            if materials, let name = sub.material?.name, !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return .init(vertices: mesh.vertexCount, faces: faces, materials: names)
    }
}

/// A 3D file flattened into sections, shared by `ModelExtractor` and `GLTFExtractor`. Totals
/// count every node and mesh, including unnamed nodes and nodes past the section cap.
struct ModelScene {
    struct Mesh {
        var name: String?
        var vertices: Int
        var faces: Int
        var materials: [String]
    }

    static let maxSections = 1_000

    private(set) var sections: [Section] = []
    private var nodes = 0, vertices = 0, faces = 0

    /// `path` is the node's names from the root (unnamed ancestors skipped), nil for an unnamed node.
    mutating func add(path: [String]?, mesh: Mesh?) {
        nodes += 1
        if let mesh { vertices += mesh.vertices; faces += mesh.faces }
        guard let path, let name = path.last, sections.count < Self.maxSections else { return }
        var lines = [name]
        if let mesh {
            if let mn = mesh.name, !mn.isEmpty, mn != name { lines.append(mn) }
            lines.append("\(Self.count(mesh.vertices, "vertex", "vertices")), \(Self.count(mesh.faces, "face", "faces"))")
            if !mesh.materials.isEmpty { lines.append("Materials: " + mesh.materials.joined(separator: ", ")) }
        }
        sections.append(Section(anchor: FileAnchor(kind: .node, value: path.joined(separator: "/")),
                                title: name, text: lines.joined(separator: "\n")))
    }

    /// Section text, then `header` (glTF scene names and generator, a binary STL's header), then totals.
    func extracted(header: [String] = [], title: String? = nil) -> Extracted {
        guard nodes > 0 || !header.isEmpty || title != nil else { return .empty }
        let totals = [Self.count(nodes, "node", "nodes"), Self.count(vertices, "vertex", "vertices"),
                      Self.count(faces, "face", "faces")].joined(separator: ", ")
        let text = (sections.map(\.text) + [(header + [totals]).joined(separator: "\n")]).joined(separator: "\n\n")
        return Extracted(text: text, sections: sections, title: title)
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

/// Wavefront OBJ, scanned line by line. Each `o` object and `g` group that has faces is a node;
/// a `g` inside an `o` nests as `Object/Group`. Faces count as triangles (an n-gon is n − 2).
/// A node's vertices are the distinct vertices its faces use, so a Maya-style file that declares
/// every vertex under `g default` still counts them where they're used. That is exact as long
/// as each node's faces are contiguous, which is how exporters write them.
private enum OBJScanner {
    private struct Node {
        var path: [String]
        var vertices = 0, faces = 0
        var materials: [String] = []
    }

    static func scan(_ url: URL, into scene: inout ModelScene) throws {
        guard TextSniffer.looksLikeText(url) else { throw ExtractError.malformed(url.path) }
        var nodes: [Node] = [], byPath: [[String]: Int] = [:]
        var object: String?, group: String?, material: String?
        var current = 0, nodeChanged = true, materialChanged = true
        var lastUser: [Int32] = []  // per vertex: the node that last counted it, or -1

        try Lines.scan(url) { key, rest in
            if key.elementsEqual("v".utf8) {
                lastUser.append(-1)
            } else if key.elementsEqual("f".utf8) {
                if nodeChanged {
                    var path = [object, group].compactMap { $0 }
                    if path.count == 2, path[0] == path[1] { path.removeLast() }
                    if let n = byPath[path] { current = n } else {
                        current = nodes.count
                        byPath[path] = current
                        nodes.append(Node(path: path))
                    }
                    nodeChanged = false
                    materialChanged = true
                }
                if materialChanged, let material, !nodes[current].materials.contains(material) {
                    nodes[current].materials.append(material)
                }
                materialChanged = false
                var corners = 0, i = 0
                while i < rest.count {
                    var negative = false, n = 0
                    if rest[i] == UInt8(ascii: "-") { negative = true; i += 1 }
                    while i < rest.count, rest[i] >= 0x30, rest[i] <= 0x39 { n = n &* 10 &+ Int(rest[i] - 0x30); i += 1 }
                    while i < rest.count, !Lines.isSpace(rest[i]) { i += 1 }
                    while i < rest.count, Lines.isSpace(rest[i]) { i += 1 }
                    corners += 1
                    let v = negative ? lastUser.count - n : n - 1
                    if v >= 0, v < lastUser.count, lastUser[v] != Int32(current) {
                        lastUser[v] = Int32(current)
                        nodes[current].vertices += 1
                    }
                }
                nodes[current].faces += max(corners - 2, 0)
            } else if key.elementsEqual("o".utf8) {
                object = Lines.string(rest); group = nil; nodeChanged = true
            } else if key.elementsEqual("g".utf8) {
                group = Lines.string(rest); nodeChanged = true
            } else if key.elementsEqual("usemtl".utf8) {
                material = Lines.string(rest); materialChanged = true
            }
        }
        for node in nodes {
            scene.add(path: node.path.isEmpty ? nil : node.path,
                      mesh: .init(vertices: node.vertices, faces: node.faces, materials: node.materials))
        }
    }
}

/// STL, read directly. A binary STL is an 80-byte header, a triangle count, and 50 bytes per
/// triangle, so its first 84 bytes give the counts; it is one unnamed node, and its header,
/// usually exporter text, is returned for the extracted text. ASCII STL is a node per `solid <name>`.
private enum STLScanner {
    static func scan(_ url: URL, into scene: inout ModelScene) throws -> [String] {
        if TextSniffer.looksLikeText(url) { try ascii(url, into: &scene); return [] }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ExtractError.unreadable(url.path) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()).map(Int.init) ?? 0
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 84), head.count == 84 else { throw ExtractError.malformed(url.path) }
        let triangles = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
        guard 84 + 50 * triangles <= size else { throw ExtractError.malformed(url.path) }
        scene.add(path: nil, mesh: .init(vertices: 3 * triangles, faces: triangles, materials: []))
        let text = head.prefix(80).prefix { $0 != 0 }
        guard text.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0x09 }) else { return [] }
        let label = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? [] : [label]
    }

    private static func ascii(_ url: URL, into scene: inout ModelScene) throws {
        var name: String?, vertices = 0, faces = 0, open = false, first = true
        var malformed = false
        func close() {
            if open { scene.add(path: name.map { [$0] }, mesh: .init(vertices: vertices, faces: faces, materials: [])) }
            open = false; vertices = 0; faces = 0
        }
        try Lines.scan(url) { key, rest in
            if first { malformed = !key.elementsEqual("solid".utf8); first = false }
            if key.elementsEqual("vertex".utf8) { vertices += 1 }
            else if key.elementsEqual("facet".utf8) { faces += 1 }
            else if key.elementsEqual("solid".utf8) { close(); name = Lines.string(rest); open = true }
            else if key.elementsEqual("endsolid".utf8) { close() }
        }
        close()
        if malformed || first { throw ExtractError.malformed(url.path) }
    }
}

/// Line-oriented reading for OBJ and ASCII STL over a memory-mapped file.
private enum Lines {
    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }

    /// Calls `body` with each non-blank line split into its first word and the rest, both trimmed.
    static func scan(_ url: URL, _ body: (_ key: UnsafeBufferPointer<UInt8>, _ rest: UnsafeBufferPointer<UInt8>) -> Void) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw ExtractError.unreadable(url.path) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var start = 0
            while start < raw.count {
                let found = memchr(base + start, 0x0A, raw.count - start)
                let nl = found.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                var i = start, end = nl
                start = nl + 1
                while i < end, isSpace(base[i]) { i += 1 }
                while end > i, isSpace(base[end - 1]) { end -= 1 }
                guard i < end else { continue }
                let keyStart = i
                while i < end, !isSpace(base[i]) { i += 1 }
                let key = UnsafeBufferPointer(start: base + keyStart, count: i - keyStart)
                while i < end, isSpace(base[i]) { i += 1 }
                body(key, UnsafeBufferPointer(start: base + i, count: end - i))
            }
        }
    }

    /// The bytes as UTF-8, or nil if there are none (a bare `o` or `solid`).
    static func string(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
