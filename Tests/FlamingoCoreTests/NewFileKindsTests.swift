import XCTest
@testable import FlamingoCore

final class NewFileKindsTests: XCTestCase {
    func testAWordNamesEveryKindItFits() {
        let threeD = DocumentFactory.search("3d").map(\.ext)
        for ext in ["shapr", "blend", "stl", "obj"] { XCTAssertTrue(threeD.contains(ext), ext) }
        XCTAssertEqual(Array(DocumentFactory.search("ppt").map(\.ext).prefix(2)), ["pptx", "key"])
        XCTAssertEqual(Array(DocumentFactory.search("word").map(\.ext).prefix(2)), ["docx", "pages"])
        XCTAssertEqual(Array(DocumentFactory.search("excel").map(\.ext).prefix(3)), ["xlsx", "numbers", "csv"])
        XCTAssertEqual(DocumentFactory.search(".stl").first?.ext, "stl")
        XCTAssertEqual(DocumentFactory.search("mind map").first?.ext, "xmind")
        XCTAssertEqual(DocumentFactory.search("").count, DocumentFactory.formats.count)
    }

    func testAnUnlistedExtensionGetsAnEmptyFileOnlyWhenEmptyIsValid() {
        XCTAssertEqual(DocumentFactory.search("zig").first?.ext, "zig")
        XCTAssertEqual(DocumentFactory.search("rs").first?.ext, "rs")
        XCTAssertFalse(DocumentFactory.search("pdf").contains { $0.ext == "pdf" })
        XCTAssertNil(DocumentFactory.blank(ext: "png"))
        XCTAssertNil(DocumentFactory.blank(ext: "../md"))
        XCTAssertNil(DocumentFactory.blank(ext: "123"))
    }

    func testEveryFileKindIsMadeAndAppOnlyKindsAreNot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in DocumentFactory.formats {
            if format.isFile {
                let url = try DocumentFactory.create(format, name: "Untitled", in: folder)
                XCTAssertEqual(url.lastPathComponent, "Untitled." + format.ext)
                if case .template = format.source {
                    XCTAssertEqual(Array(try Data(contentsOf: url).prefix(2)), [0x50, 0x4b], format.ext)
                }
            } else {
                XCTAssertThrowsError(try DocumentFactory.create(format, name: "Untitled", in: folder), format.ext)
            }
        }
        let stl = try String(contentsOf: folder.appendingPathComponent("Untitled.stl"), encoding: .utf8)
        XCTAssertTrue(stl.hasPrefix("solid"))
        let gltf = try Data(contentsOf: folder.appendingPathComponent("Untitled.gltf"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: gltf))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Untitled.shapr").path))
    }
}
