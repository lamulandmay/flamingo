import XCTest
@testable import FlamingoCore

final class FileIdentityTests: XCTestCase {
    var tv: TempVault!

    override func setUpWithError() throws { tv = try TempVault(name) }
    override func tearDown() { FileIdentity.invalidateCache(for: tv.vault); tv.destroy() }

    func testAssignsOnceThenReadsBack() throws {
        let url = tv.vault.url(for: try tv.file("a.txt"))
        XCTAssertNil(try FileIdentity.existingID(for: url))
        let id = try FileIdentity.id(for: url)
        XCTAssertEqual(try FileIdentity.id(for: url), id)
        XCTAssertEqual(try FileIdentity.existingID(for: url), id)
        XCTAssertEqual(try tv.file("a.txt", "x"), FileRef(relativePath: "a.txt"), "rewriting content")
    }

    func testIdentitySurvivesRenameAndMove() throws {
        let url = tv.vault.url(for: try tv.file("a.txt"))
        let id = try FileIdentity.id(for: url)
        try tv.rename("a.txt", to: "sub/folder/b.txt")
        XCTAssertEqual(try FileIdentity.existingID(for: tv.root.appendingPathComponent("sub/folder/b.txt")), id)
    }

    func testPackagesGetTheAttributeOnTheFolder() throws {
        let pkg = try tv.folder("deck.key")
        try tv.file("deck.key/Index.zip")
        let id = try FileIdentity.id(for: pkg)
        XCTAssertEqual(try FileIdentity.existingID(for: pkg), id)
        XCTAssertNil(try FileIdentity.existingID(for: pkg.appendingPathComponent("Index.zip")))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try FileIdentity.id(for: tv.root.appendingPathComponent("nope.txt")))
        XCTAssertThrowsError(try FileIdentity.existingID(for: tv.root.appendingPathComponent("nope.txt")))
    }

    func testGarbageAttributeIsReplaced() throws {
        let url = tv.vault.url(for: try tv.file("a.txt"))
        let junk = Array("not a uuid".utf8)
        XCTAssertEqual(setxattr(url.path, FileIdentity.xattrName, junk, junk.count, 0, 0), 0)
        XCTAssertNil(try FileIdentity.existingID(for: url))
        let id = try FileIdentity.id(for: url)
        XCTAssertEqual(try FileIdentity.existingID(for: url), id)
        let huge = [UInt8](repeating: 0x41, count: 500)
        XCTAssertEqual(setxattr(url.path, FileIdentity.xattrName, huge, huge.count, 0, 0), 0)
        XCTAssertNil(try FileIdentity.existingID(for: url))
    }

    func testAssignOverrides() throws {
        let url = tv.vault.url(for: try tv.file("a.txt"))
        let forced = UUID()
        try FileIdentity.assign(forced, to: url)
        XCTAssertEqual(try FileIdentity.id(for: url), forced)
    }

    func testLocateFindsRenamedFileAndUsesCache() throws {
        let a = try tv.file("a.txt")
        try tv.file("other.txt")
        let id = try FileIdentity.id(for: tv.vault.url(for: a))
        XCTAssertEqual(FileIdentity.locate(id: id, in: tv.vault), a)
        try tv.rename("a.txt", to: "renamed/b.txt")
        XCTAssertEqual(FileIdentity.locate(id: id, in: tv.vault), FileRef(relativePath: "renamed/b.txt"))
        XCTAssertNil(FileIdentity.locate(id: UUID(), in: tv.vault))
        try tv.remove("renamed/b.txt")
        XCTAssertNil(FileIdentity.locate(id: id, in: tv.vault), "stale cache entry is not returned")
    }

    func testIdsMapAndDuplicatePreference() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("deep/b.txt")
        let c = try tv.file("c.txt")
        let idA = try FileIdentity.id(for: tv.vault.url(for: a))
        let idB = try FileIdentity.id(for: tv.vault.url(for: b))
        try FileIdentity.assign(idB, to: tv.vault.url(for: c))   // a copy carrying the same id
        let ids = FileIdentity.ids(in: tv.vault)
        XCTAssertEqual(ids[idA], a)
        XCTAssertEqual(ids[idB], c, "shorter path wins")
        XCTAssertEqual(ids.count, 2)
    }
}
