import XCTest
@testable import Flamingo
import FlamingoCore

final class SidebarFolderTests: XCTestCase {
    @MainActor
    func testOverlappingPinsRemainDistinctAndRevealThroughTheClosestPin() throws {
        try withTree { tree, _ in
            XCTAssertTrue(tree.configurePins(["Alpha", "Alpha/Deep", "Bravo", "Charlie"]))
            XCTAssertEqual(tree.pinnedRoots.map(\.id), ["Alpha", "Alpha/Deep", "Bravo", "Charlie"])
            let canonicalAlpha = try XCTUnwrap(tree.top.first { $0.id == "Alpha" })
            let pinnedAlpha = tree.pinnedRoots[0], pinnedDeep = tree.pinnedRoots[1]
            let nestedDeep = try XCTUnwrap(tree.load(pinnedAlpha).first { $0.id == "Alpha/Deep" })
            XCTAssertFalse(canonicalAlpha === pinnedAlpha)
            XCTAssertFalse(nestedDeep === pinnedDeep)
            XCTAssertEqual(pinnedDeep.depth, 0)
            XCTAssertTrue(pinnedDeep.parent === tree.root)
            let file = try XCTUnwrap(tree.node(for: "Alpha/Deep/notes.md"))
            XCTAssertTrue(file.parent === pinnedDeep)
            XCTAssertTrue(file.isWithinPin)
            XCTAssertEqual(file.depth, 1)
        }
    }

    @MainActor
    func testFolderPreviewKeepsTheActiveFolderAndNeverTruncatesPinsOrLooseFiles() throws {
        try withTree { tree, _ in
            tree.configurePins(["Alpha", "Alpha/Deep", "Bravo", "Charlie"])
            XCTAssertEqual(tree.unpinnedRoots.map(\.id), ["Delta", "Echo", "Foxtrot", "Golf", "Hotel"])
            XCTAssertEqual(tree.visibleUnpinnedRoots(showAll: false, keepingVisible: nil).map(\.id), ["Delta", "Echo", "Foxtrot"])
            XCTAssertEqual(tree.visibleUnpinnedRoots(showAll: false, keepingVisible: "Hotel/notes.md").map(\.id), ["Delta", "Echo", "Hotel"])
            XCTAssertEqual(tree.visibleUnpinnedRoots(showAll: true, keepingVisible: nil).count, 5)
            XCTAssertEqual(tree.pinnedRoots.count, 4)
            XCTAssertEqual(tree.top.filter { !$0.isFolder }.map(\.id), ["readme.md"])
        }
    }

    @MainActor
    func testHiddenRootFoldersRemainReachableWithoutDominatingTheThreeFolderPreview() throws {
        try withTree { _, vault in
            for path in [".agents", ".android", ".antigravity"] {
                try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let tree = FileTree(vault: vault, sort: .nameAscending)
            XCTAssertEqual(tree.visibleUnpinnedRoots(showAll: false, keepingVisible: nil).map(\.id), ["Alpha", "Bravo", "Charlie"])
            XCTAssertEqual(Array(tree.visibleUnpinnedRoots(showAll: true, keepingVisible: nil).suffix(3)).map(\.id), [".agents", ".android", ".antigravity"])
            XCTAssertNotNil(tree.node(for: ".agents"))
            XCTAssertEqual(tree.visibleUnpinnedRoots(showAll: false, keepingVisible: ".android").map(\.id), ["Alpha", "Bravo", ".android"])
            let descending = FileTree(vault: vault, sort: .nameDescending)
            XCTAssertEqual(descending.visibleUnpinnedRoots(showAll: false, keepingVisible: nil).map(\.id), ["Hotel", "Golf", "Foxtrot"])
            XCTAssertEqual(Array(descending.unpinnedRoots.suffix(3)).map(\.id), [".antigravity", ".android", ".agents"])
        }
    }

    @MainActor
    func testWatcherRefreshUpdatesCanonicalAndOverlappingPinnedRepresentations() throws {
        try withTree { tree, vault in
            tree.configurePins(["Alpha", "Alpha/Deep"])
            let canonicalAlpha = try XCTUnwrap(tree.top.first { $0.id == "Alpha" })
            let canonicalDeep = try XCTUnwrap(tree.load(canonicalAlpha).first { $0.id == "Alpha/Deep" })
            tree.load(canonicalDeep)
            let nestedDeep = try XCTUnwrap(tree.load(tree.pinnedRoots[0]).first { $0.id == "Alpha/Deep" })
            tree.load(nestedDeep)
            tree.load(tree.pinnedRoots[1])
            let representations = tree.loadedNodes(at: "Alpha/Deep")
            XCTAssertEqual(representations.count, 3)
            XCTAssertTrue(representations.allSatisfy { node in tree.loadedFolders.contains { $0 === node } })
            try Data("New evidence".utf8).write(to: vault.root.appendingPathComponent("Alpha/Deep/new.md"))
            for node in representations {
                XCTAssertTrue(tree.refresh(node))
                XCTAssertTrue(node.children.contains { $0.id == "Alpha/Deep/new.md" })
            }
        }
    }

    @MainActor
    func testPinReorderRetainsObjectsAndUnpinFallsBackToCanonicalTree() throws {
        try withTree { tree, _ in
            tree.configurePins(["Alpha/Deep", "Bravo"])
            let deep = tree.pinnedRoots[0], bravo = tree.pinnedRoots[1]
            let before = try XCTUnwrap(tree.node(for: "Alpha/Deep/notes.md"))
            XCTAssertTrue(tree.configurePins(["Bravo", "Alpha/Deep", "Bravo"]))
            XCTAssertTrue(tree.pinnedRoots[0] === bravo)
            XCTAssertTrue(tree.pinnedRoots[1] === deep)
            XCTAssertTrue(tree.node(for: "Alpha/Deep/notes.md") === before)
            XCTAssertFalse(tree.configurePins(["Bravo", "Alpha/Deep"]))
            tree.configurePins(["Bravo"])
            let after = try XCTUnwrap(tree.node(for: "Alpha/Deep/notes.md"))
            XCTAssertEqual(after.id, before.id)
            XCTAssertFalse(after.isWithinPin)
            XCTAssertFalse(after === before)
        }
    }

    /// The vault root bookmarked is the whole tree, which the explorer already shows, so it
    /// is not repeated as a pin; other pins still work and invalid ones are dropped.
    @MainActor
    func testRootPinIsNotRepeated() throws {
        try withTree { tree, vault in
            tree.configurePins(["", "Alpha/Deep", "missing", "../outside"])
            XCTAssertEqual(tree.pinnedRoots.map(\.id), ["Alpha/Deep"])
            XCTAssertEqual(tree.pinnedRoots[0].name, "Deep")
            let file = try XCTUnwrap(tree.node(for: "Alpha/Deep/notes.md"))
            XCTAssertTrue(file.parent === tree.pinnedRoots[0])
            XCTAssertTrue(tree.node(for: "") === tree.root || tree.node(for: "") == nil)
            _ = vault
        }
    }

    @MainActor
    private func withTree(_ body: (FileTree, Vault) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-sidebar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Alpha/Deep", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("Evidence".utf8).write(to: root.appendingPathComponent("Alpha/Deep/notes.md"))
        try Data("Read me".utf8).write(to: root.appendingPathComponent("readme.md"))
        let vault = Vault(root: root)
        try body(FileTree(vault: vault, sort: .nameAscending), vault)
    }
}
