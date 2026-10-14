import Foundation
import FlamingoCore

/// glTF, which ModelIO can't read: nodes, meshes, and materials from the JSON (the first chunk
/// of a `.glb`). Sections match `ModelExtractor`: one per named node, anchored at its name path
/// through `children`. Unnamed nodes are walked but get no section.
public struct GLTFExtractor: Extractor {
    public static let extensions: Set<String> = ["glb", "gltf"]
    public init() {}

    private typealias JSON = [String: Any]

    public func extract(_ url: URL) throws -> Extracted {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw ExtractError.unreadable(url.path) }
        // Sniff rather than trust the extension: some `.gltf` files are binary and vice versa.
        let json = data.starts(with: Array("glTF".utf8)) ? try Self.jsonChunk(of: data, url) : data
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? JSON,
              let asset = root["asset"] as? JSON else { throw ExtractError.malformed(url.path) }

        let nodes = root["nodes"] as? [JSON] ?? []
        let accessorCounts = (root["accessors"] as? [JSON] ?? []).map { $0["count"] as? Int ?? 0 }
        let materialNames = (root["materials"] as? [JSON] ?? []).map { $0["name"] as? String }
        let meshes = (root["meshes"] as? [JSON] ?? []).map { Self.mesh($0, accessorCounts: accessorCounts, materials: materialNames) }
        let scenes = root["scenes"] as? [JSON] ?? []
        var roots = scenes.flatMap { $0["nodes"] as? [Int] ?? [] }
        if scenes.isEmpty {
            let children = Set(nodes.flatMap { $0["children"] as? [Int] ?? [] })
            roots = nodes.indices.filter { !children.contains($0) }
        }

        // Iterative, and each node visited once, so a cyclic or very deep file can't hang or overflow.
        var scene = ModelScene(), visited = Set<Int>()
        var stack: [(node: Int, parent: [String])] = roots.reversed().map { ($0, []) }
        while let (i, parent) = stack.popLast() {
            guard nodes.indices.contains(i), visited.insert(i).inserted else { continue }
            let node = nodes[i]
            let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let path = name.map { parent + [$0] } ?? parent
            let mesh = (node["mesh"] as? Int).flatMap { meshes.indices.contains($0) ? meshes[$0] : nil }
            scene.add(path: name == nil ? nil : path, mesh: mesh)
            for child in (node["children"] as? [Int] ?? []).reversed() { stack.append((child, path)) }
        }

        var header: [String] = []
        let sceneNames = scenes.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        if !sceneNames.isEmpty { header.append((sceneNames.count == 1 ? "Scene: " : "Scenes: ") + sceneNames.joined(separator: ", ")) }
        if let generator = asset["generator"] as? String, !generator.isEmpty { header.append("Generator: " + generator) }
        // Sketchfab and some other exporters put the model's title in `asset.extras`.
        let title = ((asset["extras"] as? JSON)?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return scene.extracted(header: header, title: title)
    }

    /// Vertices from each primitive's POSITION accessor. Faces by mode: 4 (or absent) is
    /// triangles, from the index count or else the vertex count; 5 and 6 are strips and fans;
    /// points and lines have none.
    private static func mesh(_ mesh: JSON, accessorCounts: [Int], materials: [String?]) -> ModelScene.Mesh {
        func count(_ accessor: Any?) -> Int? {
            (accessor as? Int).flatMap { accessorCounts.indices.contains($0) ? accessorCounts[$0] : nil }
        }
        var vertices = 0, faces = 0, names: [String] = []
        for p in mesh["primitives"] as? [JSON] ?? [] {
            let v = count((p["attributes"] as? JSON)?["POSITION"]) ?? 0
            let n = count(p["indices"]) ?? v
            vertices += v
            switch (p["mode"] as? Int) ?? 4 {
            case 4: faces += n / 3
            case 5, 6: faces += max(n - 2, 0)
            default: break
            }
            if let m = p["material"] as? Int, materials.indices.contains(m), let name = materials[m],
               !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return .init(name: mesh["name"] as? String, vertices: vertices, faces: faces, materials: names)
    }

    /// The JSON chunk of a binary glTF: a 12-byte header (`glTF`, version 2, total length), then
    /// chunks of (length, type, bytes) with JSON first. Any length that disagrees with the file,
    /// or a chunk that runs past the end, is malformed.
    private static func jsonChunk(of data: Data, _ url: URL) throws -> Data {
        func u32(_ at: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        }
        let malformed = ExtractError.malformed(url.path)
        guard data.count >= 20, u32(4) == 2, u32(8) == data.count else { throw malformed }
        var offset = 12, json: Range<Int>?
        while offset < data.count {
            guard data.count - offset >= 8 else { throw malformed }
            let length = u32(offset), type = u32(offset + 4), start = offset + 8
            guard length <= data.count - start else { throw malformed }
            if json == nil {
                guard type == 0x4E4F_534A else { throw malformed }  // "JSON"
                json = start..<start + length
            }
            offset = start + length
        }
        guard let json else { throw malformed }
        return data.subdata(in: json)
    }
}
