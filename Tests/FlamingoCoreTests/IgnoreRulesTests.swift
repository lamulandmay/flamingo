import XCTest
@testable import FlamingoCore

final class IgnoreRulesTests: XCTestCase {
    private func rules(_ text: String) -> IgnoreRules { IgnoreRules(text: text) }

    // MARK: Basename vs anchored patterns

    func testStarPatternMatchesBasenameAtAnyDepth() {
        let r = rules("*.log")
        XCTAssertTrue(r.isIgnored("a.log", isDirectory: false))
        XCTAssertTrue(r.isIgnored("x/y/b.log", isDirectory: false))
        XCTAssertFalse(r.isIgnored("a.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("a.log.bak", isDirectory: false))
    }

    func testLeadingSlashAnchorsToRoot() {
        let r = rules("/build")
        XCTAssertTrue(r.isIgnored("build", isDirectory: true))
        XCTAssertTrue(r.isIgnored("build", isDirectory: false))
        XCTAssertFalse(r.isIgnored("src/build", isDirectory: true))
    }

    func testSlashInMiddleAnchorsToRoot() {
        let r = rules("src/gen")
        XCTAssertTrue(r.isIgnored("src/gen", isDirectory: true))
        XCTAssertFalse(r.isIgnored("lib/src/gen", isDirectory: true))
        XCTAssertFalse(r.isIgnored("gen", isDirectory: true))
    }

    func testTrailingSlashMatchesDirectoriesOnly() {
        let r = rules("build/")
        XCTAssertTrue(r.isIgnored("build", isDirectory: true))
        XCTAssertFalse(r.isIgnored("build", isDirectory: false))
        XCTAssertTrue(r.isIgnored("src/build", isDirectory: true), "no other slash, so it matches at any depth")
    }

    // MARK: Double star

    func testTrailingDoubleStarMatchesContentsNotTheFolderItself() {
        let r = rules("docs/**")
        XCTAssertTrue(r.isIgnored("docs/a/b.md", isDirectory: false))
        XCTAssertTrue(r.isIgnored("docs/a", isDirectory: true))
        XCTAssertFalse(r.isIgnored("docs", isDirectory: true))
        XCTAssertFalse(r.isIgnored("other/docs/a", isDirectory: false))
    }

    func testLeadingDoubleStarMatchesAtAnyDepth() {
        let r = rules("**/temp")
        XCTAssertTrue(r.isIgnored("temp", isDirectory: true))
        XCTAssertTrue(r.isIgnored("a/temp", isDirectory: true))
        XCTAssertTrue(r.isIgnored("a/b/temp", isDirectory: false))
        XCTAssertTrue(r.isIgnored("a/temp/x.txt", isDirectory: false), "inside an ignored ancestor")
        XCTAssertFalse(r.isIgnored("temporary", isDirectory: true))
    }

    func testMiddleDoubleStarMatchesZeroOrMoreComponents() {
        let r = rules("a/**/b")
        XCTAssertTrue(r.isIgnored("a/b", isDirectory: false))
        XCTAssertTrue(r.isIgnored("a/c/b", isDirectory: false))
        XCTAssertTrue(r.isIgnored("a/c/d/b", isDirectory: false))
        XCTAssertFalse(r.isIgnored("b", isDirectory: false))
        XCTAssertFalse(r.isIgnored("x/a/b", isDirectory: false))
        XCTAssertFalse(r.isIgnored("a/bb", isDirectory: false))
    }

    // MARK: Single-character and class globs

    func testQuestionMarkMatchesExactlyOneCharacter() {
        let r = rules("file?.txt")
        XCTAssertTrue(r.isIgnored("file1.txt", isDirectory: false))
        XCTAssertTrue(r.isIgnored("sub/fileA.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("file10.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("file.txt", isDirectory: false))
    }

    func testCharacterClasses() {
        let set = rules("[abc].txt")
        XCTAssertTrue(set.isIgnored("a.txt", isDirectory: false))
        XCTAssertTrue(set.isIgnored("c.txt", isDirectory: false))
        XCTAssertFalse(set.isIgnored("d.txt", isDirectory: false))

        let range = rules("[a-c]*.md")
        XCTAssertTrue(range.isIgnored("beta.md", isDirectory: false))
        XCTAssertFalse(range.isIgnored("delta.md", isDirectory: false))

        let negated = rules("[!a-c].txt")
        XCTAssertTrue(negated.isIgnored("d.txt", isDirectory: false))
        XCTAssertFalse(negated.isIgnored("a.txt", isDirectory: false))
        XCTAssertFalse(negated.isIgnored("dd.txt", isDirectory: false))
    }

    func testNegatedClassDoesNotCrossSlashInAnchoredPattern() {
        let r = rules("src/[!x]/a.txt")
        XCTAssertTrue(r.isIgnored("src/y/a.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("src/x/a.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("src//a.txt", isDirectory: false))
    }

    func testRegexMetacharactersAreLiteral() {
        XCTAssertTrue(rules("a+b.txt").isIgnored("a+b.txt", isDirectory: false))
        XCTAssertFalse(rules("a+b.txt").isIgnored("aab.txt", isDirectory: false))
        XCTAssertTrue(rules("(x).md").isIgnored("(x).md", isDirectory: false))
        XCTAssertTrue(rules("a.b").isIgnored("a.b", isDirectory: false))
        XCTAssertFalse(rules("a.b").isIgnored("axb", isDirectory: false))
        XCTAssertTrue(rules("$HOME").isIgnored("$HOME", isDirectory: true))
    }

    func testMatchingIsCaseSensitive() {
        XCTAssertFalse(rules("*.LOG").isIgnored("a.log", isDirectory: false))
        XCTAssertTrue(rules("*.LOG").isIgnored("a.LOG", isDirectory: false))
    }

    // MARK: Negation and ordering

    func testNegationAfterPatternReIncludes() {
        let r = rules("*.log\n!keep.log")
        XCTAssertTrue(r.isIgnored("other.log", isDirectory: false))
        XCTAssertFalse(r.isIgnored("keep.log", isDirectory: false))
        XCTAssertFalse(r.isIgnored("x/keep.log", isDirectory: false))
    }

    func testNegationBeforePatternDoesNotReInclude() {
        let r = rules("!keep.log\n*.log")
        XCTAssertTrue(r.isIgnored("keep.log", isDirectory: false))
    }

    func testLastMatchWinsAcrossSeveralToggles() {
        let r = rules("*.log\n!keep.log\nkeep.*")
        XCTAssertTrue(r.isIgnored("keep.log", isDirectory: false))
    }

    func testExcludedAncestorCannotBeReIncludedFromInside() {
        let r = rules("secret/\n!secret/x.txt")
        XCTAssertTrue(r.isIgnored("secret", isDirectory: true))
        XCTAssertTrue(r.isIgnored("secret/x.txt", isDirectory: false))
        XCTAssertTrue(r.isIgnored("secret/deep/y.txt", isDirectory: false))
        XCTAssertFalse(r.isIgnored("secret", isDirectory: false), "a plain file named secret is not a directory")
        XCTAssertFalse(r.isIgnored("public/x.txt", isDirectory: false))
    }

    func testReIncludedAncestorLetsChildrenThrough() {
        let r = rules("build/\n!build/")
        XCTAssertFalse(r.isIgnored("build", isDirectory: true))
        XCTAssertFalse(r.isIgnored("build/out.o", isDirectory: false))
    }

    // MARK: Line handling

    func testCommentsAndBlankLinesAreIgnored() {
        let r = rules("# comment\n\n   \n*.log\n\t\n# trailing comment")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.isIgnored("a.log", isDirectory: false))
        XCTAssertFalse(r.isIgnored("# comment", isDirectory: false))
        XCTAssertTrue(rules("# only a comment\n\n").isEmpty)
    }

    func testHashInsideAPatternIsLiteral() {
        XCTAssertTrue(rules("a#b").isIgnored("a#b", isDirectory: false))
    }

    func testEscapedHashAndBangAreLiteral() {
        let hash = rules("\\#literal")
        XCTAssertTrue(hash.isIgnored("#literal", isDirectory: false))
        XCTAssertFalse(hash.isEmpty)

        let bang = rules("\\!bang")
        XCTAssertTrue(bang.isIgnored("!bang", isDirectory: false))
        XCTAssertFalse(bang.isIgnored("bang", isDirectory: false))
    }

    func testTrailingWhitespaceAndCarriageReturnsAreTrimmed() {
        let r = rules("*.log   \r\nbuild/\t\r\n")
        XCTAssertTrue(r.isIgnored("a.log", isDirectory: false))
        XCTAssertTrue(r.isIgnored("build", isDirectory: true))
    }

    func testLeadingSlashOnInputPathIsTolerated() {
        XCTAssertTrue(rules("/build").isIgnored("/build", isDirectory: true))
        XCTAssertTrue(rules("*.log").isIgnored("x/a.log/", isDirectory: false))
    }

    func testEmptyRulesIgnoreNothing() {
        XCTAssertTrue(IgnoreRules.empty.isEmpty)
        XCTAssertFalse(IgnoreRules.empty.isIgnored("anything", isDirectory: false))
        XCTAssertFalse(IgnoreRules.empty.isIgnored("a/b/c", isDirectory: true))
        XCTAssertFalse(IgnoreRules.empty.isIgnored("", isDirectory: true))
        XCTAssertEqual(IgnoreRules.empty, rules(""))
    }

    func testEquatableComparesParsedPatterns() {
        XCTAssertEqual(rules("*.log\nbuild/"), rules("*.log\nbuild/"))
        XCTAssertEqual(rules("*.log   \n# c\n"), rules("*.log"))
        XCTAssertNotEqual(rules("*.log"), rules("*.txt"))
        XCTAssertNotEqual(rules("build"), rules("build/"))
        XCTAssertNotEqual(rules("build"), rules("!build"))
    }

    // MARK: File loading

    func testInitContentsOfReadsFileAndMissingFileThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IgnoreRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent(IgnoreRules.fileName)
        try "*.tmp\n".write(to: file, atomically: true, encoding: .utf8)
        let loaded = try IgnoreRules(contentsOf: file)
        XCTAssertTrue(loaded.isIgnored("a.tmp", isDirectory: false))
        XCTAssertEqual(loaded, rules("*.tmp"))

        XCTAssertThrowsError(try IgnoreRules(contentsOf: dir.appendingPathComponent("missing")))
    }
}
