import XCTest
@testable import FlamingoCore

final class WikilinkTests: XCTestCase {

    // MARK: - Helpers

    private let vault = Vault(root: URL(fileURLWithPath: "/tmp/flamingo-wikilink-tests"))

    private func refs(_ paths: String...) -> [FileRef] { paths.map { FileRef(relativePath: $0) } }

    private func targets(_ text: String) -> [String] { Wikilink.links(in: text).map(\.target) }

    private func resolve(_ target: String, _ candidates: [FileRef], from source: FileRef? = nil) -> String? {
        let resolver = Wikilink.Resolver(candidates: candidates)
        if let source { return resolver.resolve(target, from: source)?.relativePath }
        return resolver.resolve(target)?.relativePath
    }

    // MARK: - parse (frozen behaviour)

    func testParsesTargetsAliasesAnchors() {
        XCTAssertEqual(Wikilink.parse("see [[a.pptx]] and [[b|B]] and [[c#slide 3]] and [[a.pptx]]"), ["a.pptx", "b", "c"])
    }

    func testParseSkipsEmptyTargetsAndKeepsFirstSeenOrder() {
        XCTAssertEqual(Wikilink.parse("[[#heading]] [[]] [[b]] [[a]] [[b|x]] [[ a ]]"), ["b", "a"])
        XCTAssertEqual(Wikilink.parse(""), [])
        XCTAssertEqual(Wikilink.parse("no links here"), [])
    }

    func testParseIsExactMatchDeduplication() {
        XCTAssertEqual(Wikilink.parse("[[A]] [[a]]"), ["A", "a"])
    }

    func testCommentLinksUsesParse() {
        let c = Comment(text: "Pricing contradicts [[q3-model.xlsx#cell Q3!B12|the model]] and [[deck]]")
        XCTAssertEqual(c.links, ["q3-model.xlsx", "deck"])
    }

    // MARK: - links(in:)

    func testLinksAreInOrderAndNotDeduplicated() {
        XCTAssertEqual(targets("[[a]] then [[b]] then [[a]]"), ["a", "b", "a"])
    }

    func testLinkRangeCoversWholeBrackets() {
        let text = "see [[a#slide 3|A]] now"
        let links = Wikilink.links(in: text)
        XCTAssertEqual(links.count, 1)
        guard let link = links.first else { return }
        XCTAssertEqual(String(text[link.range]), "[[a#slide 3|A]]")
        XCTAssertEqual(link.raw, "a#slide 3|A")
        XCTAssertEqual(link.target, "a")
        XCTAssertEqual(link.anchor, "slide 3")
        XCTAssertEqual(link.alias, "A")
        XCTAssertEqual(link.fileAnchor, FileAnchor(kind: .slide, value: "3"))
    }

    func testRawIsUntrimmedAndPartsAreTrimmed() {
        let links = Wikilink.links(in: "[[  a b  |  Alias  ]]")
        XCTAssertEqual(links.first?.raw, "  a b  |  Alias  ")
        XCTAssertEqual(links.first?.target, "a b")
        XCTAssertEqual(links.first?.alias, "Alias")
        XCTAssertNil(links.first?.anchor)
    }

    func testAliases() {
        let links = Wikilink.links(in: "[[a|Alias]] [[b]] [[c| ]]")
        XCTAssertEqual(links.map(\.target), ["a", "b", "c"])
        XCTAssertEqual(links.map(\.alias), ["Alias", nil, nil])
    }

    func testAliasMayContainHash() {
        let links = Wikilink.links(in: "[[a|see #3 and #4]]")
        XCTAssertEqual(links.first?.target, "a")
        XCTAssertEqual(links.first?.alias, "see #3 and #4")
        XCTAssertNil(links.first?.anchor)
        XCTAssertNil(links.first?.fileAnchor)
    }

    func testAnchorsAndAliasTogether() {
        let links = Wikilink.links(in: "[[deck#page 12|see this]] [[x#heading]] [[y#^block]]")
        XCTAssertEqual(links.map(\.target), ["deck", "x", "y"])
        XCTAssertEqual(links.map(\.anchor), ["page 12", "heading", "^block"])
        XCTAssertEqual(links.map(\.alias), ["see this", nil, nil])
        XCTAssertEqual(links.map(\.fileAnchor), [FileAnchor(kind: .page, value: "12"), nil, nil])
    }

    func testEmbedsCountAsLinks() {
        let text = "![[img.png]] and ![[deck.pptx#slide 2|cover]]"
        let links = Wikilink.links(in: text)
        XCTAssertEqual(links.map(\.target), ["img.png", "deck.pptx"])
        XCTAssertEqual(links.map(\.fileAnchor), [nil, FileAnchor(kind: .slide, value: "2")])
        XCTAssertEqual(links.first.map { String(text[$0.range]) }, "[[img.png]]")
        XCTAssertEqual(Wikilink.parse(text), ["img.png", "deck.pptx"])
    }

    func testEmptyTargets() {
        let links = Wikilink.links(in: "[[]] [[#Intro]] [[|alias]] [[ ]]")
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(links.map(\.target), ["", "", "", ""])
        XCTAssertEqual(links.map(\.anchor), [nil, "Intro", nil, nil])
        XCTAssertEqual(links.map(\.alias), [nil, nil, "alias", nil])
    }

    func testNestedBrackets() {
        XCTAssertEqual(targets("[[a [[b]] c]]"), ["b"])
        XCTAssertEqual(targets("[[a]b]]"), [])
        XCTAssertEqual(targets("[[a[b]]"), [])
        XCTAssertEqual(targets("[[a] ]]"), [])
        XCTAssertEqual(targets("[[[a]]"), ["a"])
        XCTAssertEqual(targets("[[a]]]"), ["a"])
        XCTAssertEqual(targets("[[ [[a]]"), ["a"])
        XCTAssertEqual(targets("[[a]] [b] [[c]]"), ["a", "c"])
        XCTAssertEqual(targets("[not] [[x]] [[y]"), ["x"])
    }

    func testNewlineInsideBracketsIsNotALink() {
        XCTAssertEqual(targets("[[a\nb]]"), [])
        XCTAssertEqual(targets("[[a\r\nb]]"), [])
        XCTAssertEqual(targets("[[a\nb]] [[c]]"), ["c"])
        XCTAssertEqual(targets("line one [[a]]\nline two [[b]]"), ["a", "b"])
    }

    func testUnclosedBracketsAtEndOfText() {
        XCTAssertEqual(targets("[[a"), [])
        XCTAssertEqual(targets("[["), [])
        XCTAssertEqual(targets("["), [])
        XCTAssertEqual(targets("[[a]"), [])
        XCTAssertEqual(targets("]]"), [])
    }

    func testSingleBacktickCodeSpanIsSkipped() {
        XCTAssertEqual(targets("see `[[not a link]]` but [[real]]"), ["real"])
        XCTAssertEqual(targets("`[[a]]` `[[b]]` [[c]]"), ["c"])
    }

    func testDoubleBacktickCodeSpanIsSkipped() {
        XCTAssertEqual(targets("``[[a]]``"), [])
        XCTAssertEqual(targets("`` ` [[a]] `` [[b]]"), ["b"], "a single backtick does not close a double-backtick span")
        XCTAssertEqual(targets("```[[a]]``` [[b]]"), ["b"])
    }

    func testUnclosedBacktickRunIsLiteral() {
        XCTAssertEqual(targets("` [[x]]"), ["x"])
        XCTAssertEqual(targets("`` [[a]] ` [[b]]"), ["a", "b"])
        XCTAssertEqual(targets("`[[a]]`` [[b]]"), ["a", "b"], "a run of two does not close a run of one")
        XCTAssertEqual(targets("[[a]] `"), ["a"])
    }

    func testCodeSpanFollowedByLinkKeepsRanges() {
        let text = "`x` [[a]]"
        let links = Wikilink.links(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first.map { String(text[$0.range]) }, "[[a]]")
    }

    func testUnicodeTargetsAndSurroundings() {
        let text = "🦩 [[café/résumé.pdf|Résumé]] 日本語 [[文書.docx]]"
        let links = Wikilink.links(in: text)
        XCTAssertEqual(links.map(\.target), ["café/résumé.pdf", "文書.docx"])
        XCTAssertEqual(links.first?.alias, "Résumé")
        XCTAssertEqual(links.map { String(text[$0.range]) }, ["[[café/résumé.pdf|Résumé]]", "[[文書.docx]]"])
    }

    func testLinksInEmptyString() {
        XCTAssertEqual(Wikilink.links(in: ""), [])
    }

    func testLinkIsHashable() {
        let links = Wikilink.links(in: "[[a]] [[a]]")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(Set(links).count, 2, "same text at different ranges are distinct links")
    }

    // MARK: - components(of:)

    func testComponentsSplitsAllThreeParts() {
        let parts = Wikilink.components(of: "target#anchor|alias")
        XCTAssertEqual(parts.target, "target")
        XCTAssertEqual(parts.anchor, "anchor")
        XCTAssertEqual(parts.alias, "alias")
    }

    func testComponentsStripsBracketsAndEmbedMarker() {
        let a = Wikilink.components(of: "[[q3.pptx#slide 3|Q3]]")
        XCTAssertEqual(a.target, "q3.pptx")
        XCTAssertEqual(a.anchor, "slide 3")
        XCTAssertEqual(a.alias, "Q3")

        let b = Wikilink.components(of: "![[img.png]]")
        XCTAssertEqual(b.target, "img.png")
        XCTAssertNil(b.anchor)
        XCTAssertNil(b.alias)

        let c = Wikilink.components(of: "  [[ spaced ]]  ")
        XCTAssertEqual(c.target, "spaced")
    }

    func testComponentsBangNotFollowedByBracketsIsPartOfTarget() {
        XCTAssertEqual(Wikilink.components(of: "!important").target, "!important")
    }

    func testComponentsAliasIsSplitBeforeAnchor() {
        let parts = Wikilink.components(of: "a|b#c")
        XCTAssertEqual(parts.target, "a")
        XCTAssertNil(parts.anchor)
        XCTAssertEqual(parts.alias, "b#c")
    }

    func testComponentsSplitAtFirstSeparatorOnly() {
        let parts = Wikilink.components(of: "a#b#c|d|e")
        XCTAssertEqual(parts.target, "a")
        XCTAssertEqual(parts.anchor, "b#c")
        XCTAssertEqual(parts.alias, "d|e")
    }

    func testComponentsTrimsEverything() {
        let parts = Wikilink.components(of: "  a  #  slide 3  |  Alias  ")
        XCTAssertEqual(parts.target, "a")
        XCTAssertEqual(parts.anchor, "slide 3")
        XCTAssertEqual(parts.alias, "Alias")
    }

    func testComponentsEmptyParts() {
        let selfLink = Wikilink.components(of: "#heading")
        XCTAssertEqual(selfLink.target, "")
        XCTAssertEqual(selfLink.anchor, "heading")

        let blankAnchor = Wikilink.components(of: "a#")
        XCTAssertEqual(blankAnchor.target, "a")
        XCTAssertNil(blankAnchor.anchor)

        let blankAlias = Wikilink.components(of: "a|  ")
        XCTAssertEqual(blankAlias.target, "a")
        XCTAssertNil(blankAlias.alias)

        let nothing = Wikilink.components(of: "")
        XCTAssertEqual(nothing.target, "")
        XCTAssertNil(nothing.anchor)
        XCTAssertNil(nothing.alias)
    }

    // MARK: - anchor(in:)

    func testAnchorForEveryKind() {
        XCTAssertEqual(Wikilink.anchor(in: "q3.pptx#slide 3"), FileAnchor(kind: .slide, value: "3"))
        XCTAssertEqual(Wikilink.anchor(in: "deck#page 12|see this"), FileAnchor(kind: .page, value: "12"))
        XCTAssertEqual(Wikilink.anchor(in: "[[q3.pptx#cell Q3!B12]]"), FileAnchor(kind: .cell, value: "Q3!B12"))
        XCTAssertEqual(Wikilink.anchor(in: "x#time 1:23"), FileAnchor(kind: .time, value: "1:23"))
        XCTAssertEqual(Wikilink.anchor(in: "model.xlsx#sheet Revenue"), FileAnchor(kind: .sheet, value: "Revenue"))
        XCTAssertEqual(Wikilink.anchor(in: "main.swift#line 40"), FileAnchor(kind: .line, value: "40"))
        XCTAssertEqual(Wikilink.anchor(in: "scene.usdz#node Root/Mesh"), FileAnchor(kind: .node, value: "Root/Mesh"))
        XCTAssertEqual(Wikilink.anchor(in: "photo.jpg#region 10,20,30,40"), FileAnchor(kind: .region, value: "10,20,30,40"))
        for kind in FileAnchor.Kind.allCases {
            XCTAssertEqual(Wikilink.anchor(in: "f#\(kind.rawValue) v"), FileAnchor(kind: kind, value: "v"))
        }
    }

    func testAnchorKindIsCaseInsensitiveAndValueKeepsCase() {
        XCTAssertEqual(Wikilink.anchor(in: "a#SLIDE 3"), FileAnchor(kind: .slide, value: "3"))
        XCTAssertEqual(Wikilink.anchor(in: "a#Cell q3!b12"), FileAnchor(kind: .cell, value: "q3!b12"))
    }

    func testAnchorValueMayContainSpacesAndExtraWhitespaceIsTrimmed() {
        XCTAssertEqual(Wikilink.anchor(in: "a#region top left"), FileAnchor(kind: .region, value: "top left"))
        XCTAssertEqual(Wikilink.anchor(in: "a#slide    3   "), FileAnchor(kind: .slide, value: "3"))
        XCTAssertEqual(Wikilink.anchor(in: "a#slide\t3"), FileAnchor(kind: .slide, value: "3"))
    }

    func testAnchorNegativeCases() {
        XCTAssertNil(Wikilink.anchor(in: "a#heading"))
        XCTAssertNil(Wikilink.anchor(in: "a#^block"))
        XCTAssertNil(Wikilink.anchor(in: "a#foo 3"), "unknown kind")
        XCTAssertNil(Wikilink.anchor(in: "a#slide"), "kind without value")
        XCTAssertNil(Wikilink.anchor(in: "a#slide "), "kind with blank value")
        XCTAssertNil(Wikilink.anchor(in: "a#slides 3"), "kind must match exactly")
        XCTAssertNil(Wikilink.anchor(in: "a"), "no anchor")
        XCTAssertNil(Wikilink.anchor(in: "slide 3"), "no # separator")
        XCTAssertNil(Wikilink.anchor(in: "a|slide 3"), "anchor syntax inside the alias does not count")
        XCTAssertNil(Wikilink.anchor(in: ""))
    }

    // MARK: - Resolution tiers

    func testTier1ExactRelativePath() {
        let c = refs("decks/q3.pptx", "q3.pptx", "archive/decks/q3.pptx")
        XCTAssertEqual(resolve("decks/q3.pptx", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c), "q3.pptx")
        XCTAssertEqual(resolve("archive/decks/q3.pptx", c), "archive/decks/q3.pptx")
    }

    func testTier2RelativePathWithoutExtension() {
        XCTAssertEqual(resolve("decks/q3", refs("decks/q3.pptx", "q3.pptx")), "decks/q3.pptx")
        XCTAssertEqual(resolve("decks/q3", refs("decks/q3.pptx", "decks/q3")), "decks/q3", "an exact path beats a path without extension")
        XCTAssertEqual(resolve("decks/q3.pptx", refs("decks/q3.pptx.md", "decks/q3.pptx")), "decks/q3.pptx")
    }

    func testTier3Basename() {
        XCTAssertEqual(resolve("q3.pptx", refs("decks/q3.pptx", "models/q3.xlsx")), "decks/q3.pptx")
        XCTAssertEqual(resolve("q3", refs("a/q3.pptx", "b/q3")), "b/q3", "an exact basename beats a basename without extension")
    }

    func testTier4BasenameWithoutExtension() {
        XCTAssertEqual(resolve("q3", refs("decks/q3.pptx", "notes/other.md")), "decks/q3.pptx")
        XCTAssertEqual(resolve("note", refs("notes/note.md", "notes/other.md")), "notes/note.md")
        XCTAssertEqual(resolve("[[note]]", refs("notes/note.md")), "notes/note.md")
    }

    func testCaseInsensitiveFallbackTiers() {
        let c = refs("Decks/Q3.pptx", "notes/Note.md")
        XCTAssertEqual(resolve("decks/q3.pptx", c), "Decks/Q3.pptx", "tier 5: path")
        XCTAssertEqual(resolve("DECKS/Q3", c), "Decks/Q3.pptx", "tier 6: path without extension")
        XCTAssertEqual(resolve("q3.PPTX", c), "Decks/Q3.pptx", "tier 7: basename")
        XCTAssertEqual(resolve("q3", c), "Decks/Q3.pptx", "tier 8: basename without extension")
        XCTAssertEqual(resolve("NOTE", c), "notes/Note.md")
    }

    func testExactCaseBeatsCaseInsensitiveEvenWhenItSortsLater() {
        let c = refs("a/Q3.pptx", "b/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c), "b/q3.pptx")
        XCTAssertEqual(resolve("Q3.pptx", c), "a/Q3.pptx")
        XCTAssertEqual(resolve("q3", c), "b/q3.pptx")
        XCTAssertEqual(resolve("Q3", c), "a/Q3.pptx")
    }

    func testEveryTierBeatsTheNextOne() {
        // Each candidate matches "x" at exactly one tier; removing the winner reveals the next.
        var c = refs("d/X.txt", "d/X", "d/x.txt", "d/x", "x.txt", "x")
        let expected = ["x", "x.txt", "d/x", "d/x.txt", "d/X", "d/X.txt"]
        for want in expected {
            XCTAssertEqual(resolve("x", c), want)
            c.removeAll { $0.relativePath == want }
        }
        XCTAssertNil(resolve("x", c))
    }

    func testQueryNormalization() {
        let c = refs("decks/q3.pptx")
        XCTAssertEqual(resolve("./decks/q3.pptx", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("/decks/q3.pptx", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("decks/q3.pptx/", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("decks\\q3.pptx", c), "decks/q3.pptx")
        XCTAssertEqual(resolve(".\\decks\\q3.pptx", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("  decks/q3.pptx  ", c), "decks/q3.pptx")
    }

    func testQueryMayCarryAnchorAliasAndBrackets() {
        let c = refs("decks/q3.pptx")
        XCTAssertEqual(resolve("decks/q3.pptx#slide 3", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("q3|Quarter three", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("[[q3.pptx#slide 3|Q3]]", c), "decks/q3.pptx")
        XCTAssertEqual(resolve("![[decks/q3.pptx]]", c), "decks/q3.pptx")
    }

    func testEmptyAndUnresolvableTargets() {
        let c = refs("decks/q3.pptx")
        XCTAssertNil(resolve("", c))
        XCTAssertNil(resolve("   ", c))
        XCTAssertNil(resolve("[[]]", c))
        XCTAssertNil(resolve("#heading", c))
        XCTAssertNil(resolve("|alias", c))
        XCTAssertNil(resolve("/", c))
        XCTAssertNil(resolve("./", c))
        XCTAssertNil(resolve("q4", c))
        XCTAssertNil(resolve("q3.xlsx", c))
        XCTAssertNil(resolve("decks", c), "a folder is not a file")
        XCTAssertNil(resolve("anything", []))
    }

    func testCandidatePathsAreNormalizedToo() {
        XCTAssertEqual(resolve("decks/q3.pptx", refs("decks\\q3.pptx")), "decks\\q3.pptx")
    }

    // MARK: - Tie-breaking

    func testSameFolderPreferenceWithSource() {
        let c = refs("a/q3.pptx", "b/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c, from: FileRef(relativePath: "b/notes.md")), "b/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c, from: FileRef(relativePath: "a/notes.md")), "a/q3.pptx")
        XCTAssertEqual(resolve("q3", c, from: FileRef(relativePath: "b/notes.md")), "b/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c, from: FileRef(relativePath: "c/notes.md")), "a/q3.pptx", "no same-folder match falls back to the normal order")
        XCTAssertEqual(resolve("q3.pptx", c), "a/q3.pptx")
    }

    func testRootLevelSourceFallsBackToNormalOrder() {
        let c = refs("b/q3.pptx", "a/q3.pptx")
        XCTAssertEqual(resolve("q3", c, from: FileRef(relativePath: "readme.md")), "a/q3.pptx")
    }

    func testTierWinsBeforeSameFolderTieBreak() {
        // A root-level file's path without extension is "q3" (tier 2), which beats the nested
        // file's basename-without-extension match (tier 4) even though the source sits beside it.
        let c = refs("a/q3.pptx", "q3.pptx")
        XCTAssertEqual(resolve("q3", c, from: FileRef(relativePath: "a/readme.md")), "q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c, from: FileRef(relativePath: "a/readme.md")), "q3.pptx")
    }

    func testSameFolderBeatsFewestComponents() {
        let c = refs("x/q3.pptx", "deep/er/q3.pptx")
        XCTAssertEqual(resolve("q3", c, from: FileRef(relativePath: "deep/er/notes.md")), "deep/er/q3.pptx")
        XCTAssertEqual(resolve("q3", c), "x/q3.pptx")
    }

    func testSameFolderDoesNotOverrideTier() {
        let c = refs("a/q3.pptx", "b/q3")
        XCTAssertEqual(resolve("q3", c, from: FileRef(relativePath: "a/notes.md")), "b/q3", "exact basename (tier 3) still beats basename without extension in the same folder")
    }

    func testFewestComponentsBeatsAlphabetical() {
        let c = refs("a/b/q3.pptx", "z/q3.pptx")
        XCTAssertEqual(resolve("q3", c), "z/q3.pptx")
        XCTAssertEqual(resolve("q3.pptx", c), "z/q3.pptx")
    }

    func testAlphabeticalTieBreakIsLocalizedStandard() {
        let c = refs("q10/x.md", "q2/x.md", "q1/x.md")
        XCTAssertEqual(resolve("x", c), "q1/x.md")
        XCTAssertEqual(resolve("x", refs("q10/x.md", "q2/x.md")), "q2/x.md", "numeric-aware ordering")
    }

    func testResultIsIndependentOfCandidateOrder() {
        let forward = refs("z/q3.pptx", "a/b/q3.pptx", "m/q3.pptx", "b/q3.pptx")
        let backward = Array(forward.reversed())
        XCTAssertEqual(resolve("q3", forward), "b/q3.pptx")
        XCTAssertEqual(resolve("q3", backward), "b/q3.pptx")
        XCTAssertEqual(resolve("q3", forward, from: FileRef(relativePath: "m/n.md")), "m/q3.pptx")
        XCTAssertEqual(resolve("q3", backward, from: FileRef(relativePath: "m/n.md")), "m/q3.pptx")
    }

    func testDuplicateCandidatesAreHarmless() {
        let c = refs("a/q3.pptx", "a/q3.pptx", "b/q3.pptx")
        XCTAssertEqual(resolve("q3", c), "a/q3.pptx")
    }

    // MARK: - Unicode normalization

    func testNFCAndNFDQueriesAndCandidatesAreEquivalent() {
        let composed = "caf\u{E9}.md"          // é as one scalar
        let decomposed = "cafe\u{301}.md"      // e + combining acute
        // Swift's == is canonical equivalence, so compare scalars to prove the two forms really differ.
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))

        XCTAssertEqual(resolve(decomposed, refs(composed)), composed)
        XCTAssertEqual(resolve(composed, refs(decomposed)), decomposed)
        XCTAssertEqual(resolve("cafe\u{301}", refs("notes/" + composed)), "notes/" + composed)
        XCTAssertEqual(resolve("notes/caf\u{E9}", refs("notes/" + decomposed)), "notes/" + decomposed)
    }

    func testNFDQueryWithDifferentCaseStillResolves() {
        XCTAssertEqual(resolve("CAFE\u{301}", refs("notes/caf\u{E9}.md")), "notes/caf\u{E9}.md")
        XCTAssertEqual(resolve("Caf\u{E9}.MD", refs("notes/cafe\u{301}.md")), "notes/cafe\u{301}.md")
    }

    // MARK: - Static wrappers and Resolver reuse

    func testStaticResolveMatchesResolver() {
        let c = refs("decks/q3.pptx", "a/q3.pptx", "b/q3.pptx")
        XCTAssertEqual(Wikilink.resolve("decks/q3", in: vault, candidates: c), FileRef(relativePath: "decks/q3.pptx"))
        XCTAssertEqual(Wikilink.resolve("q3", in: vault, candidates: c), FileRef(relativePath: "a/q3.pptx"))
        XCTAssertEqual(Wikilink.resolve("q3", from: FileRef(relativePath: "b/x.md"), in: vault, candidates: c), FileRef(relativePath: "b/q3.pptx"))
        XCTAssertNil(Wikilink.resolve("nope", in: vault, candidates: c))
        XCTAssertNil(Wikilink.resolve("", from: FileRef(relativePath: "b/x.md"), in: vault, candidates: c))
    }

    func testResolverReuseOverThousandsOfCandidates() {
        var candidates: [FileRef] = []
        for i in 0..<4000 {
            candidates.append(FileRef(relativePath: "dir\(i % 50)/sub\(i % 7)/file\(i).md"))
        }
        candidates.append(FileRef(relativePath: "README"))
        candidates.append(FileRef(relativePath: "decks/Q3 Review.pptx"))
        let resolver = Wikilink.Resolver(candidates: candidates)

        for i in stride(from: 0, to: 4000, by: 3) {
            let expected = "dir\(i % 50)/sub\(i % 7)/file\(i).md"
            XCTAssertEqual(resolver.resolve("file\(i)")?.relativePath, expected)
            XCTAssertEqual(resolver.resolve("FILE\(i).MD")?.relativePath, expected)
            XCTAssertEqual(resolver.resolve(expected)?.relativePath, expected)
            XCTAssertEqual(resolver.resolve("[[file\(i)#line 3|see]]", from: FileRef(relativePath: "README"))?.relativePath, expected)
        }
        XCTAssertEqual(resolver.resolve("readme")?.relativePath, "README")
        XCTAssertEqual(resolver.resolve("q3 review")?.relativePath, "decks/Q3 Review.pptx")
        XCTAssertNil(resolver.resolve("file4000"))
        XCTAssertNil(resolver.resolve("dir1"))
    }
}
