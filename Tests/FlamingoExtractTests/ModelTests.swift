import Foundation
import ModelIO
import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class ModelTests: XCTestCase {
    private func section(_ e: Extracted, _ path: String) -> Section? {
        e.sections.first { $0.anchor == FileAnchor(kind: .node, value: path) }
    }

    // MARK: ModelIO

    func testUSDAHierarchyCountsAndMaterials() throws {
        let e = try ModelExtractor().extract(Fixtures.url("scene.usda"))
        XCTAssertEqual(Set(e.sections.map(\.anchor.value)), ["Robot", "Robot/Arm", "Robot/Arm/Hand", "Robot/Torso", "Robot/Looks"])
        XCTAssertEqual(section(e, "Robot/Arm/Hand")?.title, "Hand")
        XCTAssertEqual(section(e, "Robot/Arm/Hand")?.text, "Hand\n4 vertices, 2 faces\nMaterials: Rubber")
        XCTAssertEqual(section(e, "Robot/Torso")?.text, "Torso\n8 vertices, 12 faces\nMaterials: Steel")
        XCTAssertEqual(section(e, "Robot/Arm")?.text, "Arm")
        XCTAssertTrue(e.text.hasSuffix("5 nodes, 12 vertices, 14 faces"), e.text)
        XCTAssertNil(e.title)
    }

    func testUSDZMatchesItsUSDA() throws {
        let dir = try Fixtures.tempDir(self)
        let usdz = dir.appendingPathComponent("scene.usdz")
        try Self.storedZip([Fixtures.url("scene.usda")], to: usdz)
        let e = try ModelExtractor().extract(usdz)
        XCTAssertEqual(e, try ModelExtractor().extract(Fixtures.url("scene.usda")))
        XCTAssertEqual(try Extract.extract(usdz).sections.count, 5)
    }

    func testOBJObjectsGroupsAndMaterials() throws {
        let e = try ModelExtractor().extract(Fixtures.url("robot.obj"))
        XCTAssertEqual(e.sections.map(\.anchor.value), ["Body", "Head", "Head/Antenna"])
        XCTAssertEqual(e.sections.map(\.title), ["Body", "Head", "Antenna"])
        XCTAssertEqual(section(e, "Body")?.text, "Body\n8 vertices, 12 faces\nMaterials: Steel")
        XCTAssertEqual(section(e, "Head")?.text, "Head\n5 vertices, 6 faces\nMaterials: Steel, Visor")
        // `usemtl Visor` carries into the group; negative and v/vt/vn indices resolve.
        XCTAssertEqual(section(e, "Head/Antenna")?.text, "Antenna\n3 vertices, 1 face\nMaterials: Visor")
        XCTAssertTrue(e.text.hasSuffix("3 nodes, 16 vertices, 19 faces"), e.text)
    }

    func testOBJVerticesDeclaredInAnotherGroup() throws {
        // Maya writes every vertex under `g default`, then the faces under the real group.
        let url = try write("g default\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\ng pPlane1\nusemtl lambert2SG\nf 1 2 3 4\n", "plane.obj")
        let e = try ModelExtractor().extract(url)
        XCTAssertEqual(e.sections.map(\.anchor.value), ["pPlane1"])
        XCTAssertEqual(e.sections.first?.text, "pPlane1\n4 vertices, 2 faces\nMaterials: lambert2SG")
    }

    func testSTL() throws {
        let e = try ModelExtractor().extract(Fixtures.url("part.stl"))
        XCTAssertEqual(e.sections, [Section(anchor: FileAnchor(kind: .node, value: "Bracket"), title: "Bracket",
                                            text: "Bracket\n9 vertices, 3 faces")])
        XCTAssertEqual(e.text, "Bracket\n9 vertices, 3 faces\n\n1 node, 9 vertices, 3 faces")

        let two = try write("solid Left\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid Left\nsolid Right\r\nendsolid Right\r\n", "two.stl")
        XCTAssertEqual(try ModelExtractor().extract(two).sections.map(\.text), ["Left\n3 vertices, 1 face", "Right\n0 vertices, 0 faces"])
    }

    func testBinarySTLReadsOnlyItsHeader() throws {
        // A binary STL whose header starts with "solid", as many exporters write, is still binary.
        var stl = Data("solid Gear exported by Flamingo".utf8)
        stl += Data(count: 80 - stl.count)
        stl += withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }
        stl += Data(count: 2 * 50)
        let url = try write("", "gear.stl")
        try stl.write(to: url)
        let e = try ModelExtractor().extract(url)
        XCTAssertEqual(e.sections, [])
        XCTAssertEqual(e.text, "solid Gear exported by Flamingo\n1 node, 6 vertices, 2 faces")
        try stl.prefix(84 + 60).write(to: url)
        XCTAssertThrowsError(try ModelExtractor().extract(url))
    }

    func testCorruptModelsThrowAndEmptyStageIsEmpty() throws {
        let dir = try Fixtures.tempDir(self)
        let usda = try String(contentsOf: Fixtures.url("scene.usda"))
        let cases: [(String, Data)] = [
            ("truncated.usda", Data(usda.prefix(300).utf8)),
            ("noise.usdz", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })),
            ("text.usdc", Data("not a crate file".utf8)),
            ("empty.stl", Data()),
            ("noise.stl", Data(repeating: 0xA5, count: 300)),
            ("binary.obj", Data([0, 1, 2, 3, 0, 0, 0xFF, 0xFE] + Array(repeating: 0, count: 64))),
        ]
        for (name, data) in cases {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertThrowsError(try ModelExtractor().extract(url), name) {
                XCTAssertEqual($0 as? ExtractError, .malformed(url.path), name)
            }
        }
        let empty = dir.appendingPathComponent("empty.usda")
        try Data("#usda 1.0\n".utf8).write(to: empty)
        XCTAssertEqual(try ModelExtractor().extract(empty), .empty)
    }

    func testSectionCap() throws {
        var obj = "v 0 0 0\nv 1 0 0\nv 0 1 0\n"
        for i in 0..<1_200 { obj += "o Part\(i)\nf 1 2 3\n" }
        let e = try ModelExtractor().extract(try write(obj, "many.obj"))
        XCTAssertEqual(e.sections.count, ModelScene.maxSections)
        XCTAssertEqual(e.sections.last?.anchor.value, "Part999")
        XCTAssertTrue(e.text.hasSuffix("1200 nodes, 3600 vertices, 1200 faces"), String(e.text.suffix(80)))
    }

    func testConcurrentExtraction() throws {
        let urls = ["scene.usda", "robot.obj", "part.stl", "box.glb"].map(Fixtures.url)
        let expected = try urls.map { try Extract.extract($0) }
        let results = Locked<[Int: Extracted]>([:])
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let e = try? Extract.extract(urls[i % urls.count])
            results.withLock { $0[i] = e }
        }
        let got = results.withLock { $0 }
        for i in 0..<64 { XCTAssertEqual(got[i], expected[i % urls.count], "iteration \(i)") }
    }

    func testTenMegabyteUSDZBenchmark() throws {
        let dir = try Fixtures.tempDir(self)
        let usdz = try Self.bigUSDZ(in: dir)
        let size = try usdz.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 10_000_000)
        var e = Extracted.empty
        let t = try Fixtures.time { e = try ModelExtractor().extract(usdz) }
        #if DEBUG
        print("ModelTests: \(String(format: "%.1f", Double(size) / 1e6)) MB usdz extracted in \(String(format: "%.3f", t)) s")
        #endif
        // ModelIO's exporter roots the stage at the file name, with a `Geom` scope under it.
        XCTAssertEqual(e.sections.count, 3 + 4 + 28)
        XCTAssertEqual(section(e, "big/Geom/Assembly/Group2/Part10")?.text, "Part10\n20000 vertices, 30000 faces\nMaterials: Paint10")
        XCTAssertTrue(e.text.hasSuffix("35 nodes, 560000 vertices, 840000 faces"), String(e.text.suffix(80)))
        XCTAssertLessThan(t, 1.0)
    }

    // MARK: glTF

    func testGLBNodesMeshesMaterials() throws {
        let e = try GLTFExtractor().extract(Fixtures.url("box.glb"))
        XCTAssertEqual(e.sections.map(\.anchor.value), ["Robot", "Robot/Arm", "Robot/Arm/Hand", "Robot/Body", "Robot/Antenna"])
        XCTAssertEqual(section(e, "Robot/Body")?.text, "Body\nBoxMesh\n8 vertices, 12 faces\nMaterials: Steel")
        // Two non-indexed triangles plus a line primitive, which adds vertices but no faces.
        XCTAssertEqual(section(e, "Robot/Arm/Hand")?.text, "Hand\nHandMesh\n8 vertices, 2 faces\nMaterials: Rubber")
        // The unnamed group under Robot is walked: its child is reached, it gets no section.
        XCTAssertEqual(section(e, "Robot/Antenna")?.title, "Antenna")
        XCTAssertTrue(e.text.hasSuffix("Scene: Workshop\nGenerator: Flamingo fixture builder\n6 nodes, 16 vertices, 14 faces"), e.text)
        XCTAssertNil(e.title)
    }

    func testGLTFJSONAndTitle() throws {
        var json = try JSONSerialization.jsonObject(with: Data(Self.glbJSON.utf8)) as! [String: Any]
        json["asset"] = ["version": "2.0", "extras": ["title": "Shop Robot"]]
        let url = try Fixtures.tempDir(self).appendingPathComponent("robot.gltf")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let e = try GLTFExtractor().extract(url)
        XCTAssertEqual(e.sections, try GLTFExtractor().extract(Fixtures.url("box.glb")).sections)
        XCTAssertEqual(e.title, "Shop Robot")
        XCTAssertTrue(e.text.hasSuffix("Scene: Workshop\n6 nodes, 16 vertices, 14 faces"), e.text)
    }

    func testMalformedGLBThrows() throws {
        let good = try Data(contentsOf: Fixtures.url("box.glb"))
        func patched(_ at: Int, _ value: UInt32) -> Data {
            var d = good
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(at..<at + 4, with: $0) }
            return d
        }
        let cases: [(String, Data)] = [
            ("truncated", good.prefix(good.count - 10)),
            ("header only", good.prefix(12)),
            ("version 1", patched(4, 1)),
            ("length too long", patched(8, UInt32(good.count + 4))),
            ("chunk past end", patched(12, 1 << 20)),
            ("BIN first", patched(16, 0x004E_4942)),
            ("not glTF", Data("{\"nodes\": []}".utf8)),
            ("empty", Data()),
        ]
        let dir = try Fixtures.tempDir(self)
        for (name, data) in cases {
            let url = dir.appendingPathComponent("bad.glb")
            try data.write(to: url)
            XCTAssertThrowsError(try GLTFExtractor().extract(url), name) {
                XCTAssertEqual($0 as? ExtractError, .malformed(url.path), name)
            }
        }
    }

    func testCyclicNodesTerminate() throws {
        let json = #"{"asset":{"version":"2.0"},"nodes":[{"name":"A","children":[1]},{"name":"B","children":[0,1,7]}],"scenes":[{"nodes":[0]}]}"#
        let e = try GLTFExtractor().extract(try write(json, "loop.gltf"))
        XCTAssertEqual(e.sections.map(\.anchor.value), ["A", "A/B"])
    }

    /// Rewrites `Fixtures/box.glb` when `FLAMINGO_REGENERATE_FIXTURES=1`; otherwise checks the
    /// committed file is still exactly what the builder makes.
    func testBoxGLBFixtureIsReproducible() throws {
        let built = Self.boxGLB()
        if ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1" {
            try built.write(to: Fixtures.url("box.glb"))
        }
        XCTAssertEqual(try Data(contentsOf: Fixtures.url("box.glb")), built)
    }

    // MARK: Builders

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = try Fixtures.tempDir(self).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// usdz members must be stored, not deflated; `Fixtures.zip` deflates.
    private static func storedZip(_ files: [URL], to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-0", "-X", "-q", "-j", url.path] + files.map(\.path)
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    /// `Assembly/Group0…3/Part0…27`, each part 20,000 seeded-random vertices (all used) and
    /// 30,000 triangles, exported by ModelIO as usdc and stored in a usdz: about 10 MB.
    private static func bigUSDZ(in dir: URL) throws -> URL {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt32 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return UInt32(seed >> 33) }
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        let allocator = MDLMeshBufferDataAllocator()
        let root = MDLObject()
        root.name = "Assembly"
        let groups = (0..<4).map { g -> MDLObject in
            let o = MDLObject()
            o.name = "Group\(g)"
            root.addChild(o)
            return o
        }
        for i in 0..<28 {
            let positions = (0..<60_000).map { _ in Float(next() % 20_000) / 10_000 - 1 }
            let indices = (0..<90_000).map { $0 < 20_000 ? UInt32($0) : next() % 20_000 }
            let vertices = allocator.newBuffer(with: positions.withUnsafeBytes { Data($0) }, type: .vertex)
            let index = allocator.newBuffer(with: indices.withUnsafeBytes { Data($0) }, type: .index)
            let material = MDLMaterial(name: "Paint\(i)", scatteringFunction: MDLScatteringFunction())
            let sub = MDLSubmesh(name: "s", indexBuffer: index, indexCount: indices.count, indexType: .uInt32,
                                 geometryType: .triangles, material: material)
            let mesh = MDLMesh(vertexBuffer: vertices, vertexCount: 20_000, descriptor: descriptor, submeshes: [sub])
            mesh.name = "Part\(i)"
            groups[i % 4].addChild(mesh)
        }
        let asset = MDLAsset()
        asset.add(root)
        let usdc = dir.appendingPathComponent("big.usdc")
        try asset.export(to: usdc)
        let usdz = dir.appendingPathComponent("big.usdz")
        try storedZip([usdc], to: usdz)
        return usdz
    }

    /// The JSON chunk of `box.glb`, also used as a `.gltf`.
    static let glbJSON = """
    {"asset":{"version":"2.0","generator":"Flamingo fixture builder"},"scene":0,\
    "scenes":[{"name":"Workshop","nodes":[0]}],\
    "nodes":[{"name":"Robot","children":[1,3,4]},{"name":"Arm","children":[2]},{"name":"Hand","mesh":1},\
    {"name":"Body","mesh":0},{"children":[5]},{"name":"Antenna"}],\
    "meshes":[{"name":"BoxMesh","primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]},\
    {"name":"HandMesh","primitives":[{"attributes":{"POSITION":2},"material":1},{"attributes":{"POSITION":3},"mode":1}]}],\
    "materials":[{"name":"Steel"},{"name":"Rubber"}],\
    "accessors":[{"bufferView":0,"componentType":5126,"count":8,"type":"VEC3","min":[-1,-1,-1],"max":[1,1,1]},\
    {"bufferView":1,"componentType":5123,"count":36,"type":"SCALAR"},\
    {"bufferView":2,"componentType":5126,"count":6,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},\
    {"bufferView":3,"componentType":5126,"count":2,"type":"VEC3","min":[0,0,0],"max":[0,1,0]}],\
    "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":96,"target":34962},\
    {"buffer":0,"byteOffset":96,"byteLength":72,"target":34963},\
    {"buffer":0,"byteOffset":168,"byteLength":72,"target":34962},\
    {"buffer":0,"byteOffset":240,"byteLength":24,"target":34962}],\
    "buffers":[{"byteLength":264}]}
    """

    /// A valid binary glTF: header, JSON chunk padded with spaces, BIN chunk with the box
    /// (8 corners, 36 indices), the hand (two loose triangles), and a two-point line.
    static func boxGLB() -> Data {
        let corners: [Float] = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]
        let indices: [UInt16] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                                 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        let hand: [Float] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0]
        let line: [Float] = [0, 0, 0, 0, 1, 0]
        var bin = Data()
        corners.withUnsafeBytes { bin.append(contentsOf: $0) }
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        hand.withUnsafeBytes { bin.append(contentsOf: $0) }
        line.withUnsafeBytes { bin.append(contentsOf: $0) }
        var json = Data(glbJSON.utf8)
        while json.count % 4 != 0 { json.append(0x20) }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        var out = Data("glTF".utf8) + u32(2) + u32(12 + 8 + json.count + 8 + bin.count)
        out += u32(json.count) + Data("JSON".utf8) + json
        out += u32(bin.count) + Data("BIN\0".utf8) + bin
        return out
    }
}
