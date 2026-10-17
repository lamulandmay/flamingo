import XCTest
@testable import FlamingoIndex

final class MentionLimitTests: XCTestCase {
    func testMachineListingsNeitherMentionNorAreMentioned() {
        for path in ["miniconda3/pkgs/numpy/info/RECORD", "env/conda-meta/paths.json", "app/node_modules/x/index.js",
                     "lib/python3.12/site-packages/foo/bar.py", "repo/.git/HEAD", "proj/build/out.md",
                     "pkg/foo-1.0.dist-info/METADATA", "web/package-lock.json", "logs/server.log",
                     ".codex/sessions/run.jsonl", "Cargo.lock"] {
            XCTAssertTrue(IndexStore.isMachineListing(path), path)
        }
        for path in ["notes/arc launch plan.md", "decks/q3-model.pptx", "research/build notes.md", "README.md"] {
            XCTAssertFalse(IndexStore.isMachineListing(path), path)
        }
    }

    func testStrongestMentionsCapEachFileAndEachSource() {
        var weights: [EdgeKey: Double] = [:]
        // One list names 30 files; one popular file is named by 10 others.
        for i in 0..<30 { weights[EdgeKey(source: "list.md", target: "t\(i).md", kind: .mention)] = Double(30 - i) }
        for i in 0..<10 { weights[EdgeKey(source: "memo\(i).md", target: "popular.md", kind: .mention)] = Double(i) + 0.5 }
        let kept = IndexStore.strongestMentions(weights)
        var degree: [String: Int] = [:]
        for key in kept.keys { degree[key.source, default: 0] += 1; degree[key.target, default: 0] += 1 }
        XCTAssertEqual(degree["list.md"], IndexStore.mentionNodeCap)
        XCTAssertEqual(degree["popular.md"], IndexStore.mentionNodeCap)
        XCTAssertNotNil(kept[EdgeKey(source: "list.md", target: "t0.md", kind: .mention)], "the strongest survive")
        XCTAssertNil(kept[EdgeKey(source: "list.md", target: "t29.md", kind: .mention)])
        XCTAssertNotNil(kept[EdgeKey(source: "memo9.md", target: "popular.md", kind: .mention)])
        XCTAssertEqual(IndexStore.strongestMentions(weights), kept, "deterministic")
    }
}
