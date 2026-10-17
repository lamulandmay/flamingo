import XCTest
@testable import FlamingoCore

/// A frozen copy of the sidecar parser as it was before thoughts v2 (checkpoint 164b2bc).
/// It is the stand-in for an older Flamingo build reading a note this build wrote: if the
/// notes stay readable by it, with nothing leaking into thought text, they stay readable
/// by anything that treats the hidden lines as HTML comments, Obsidian included.
/// Do not "fix" or modernize this copy.
enum FrozenV1Parser {
    struct Parsed: Equatable {
        var timestamp: String
        var anchor: FileAnchor?
        var text: String
        var provenance: CommentProvenance?
    }

    static func parse(_ text: String) -> [Parsed] {
        guard !text.isEmpty else { return [] }
        var lines = splitLines(text)
        if lines.last == "" { lines.removeLast() }
        if lines.first?.hasSuffix("\r") == true { lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }
        var bodyStart = 0
        if lines.first == "---", let close = lines[1...].firstIndex(of: "---") { bodyStart = close + 1 }
        var out: [Parsed] = []
        var current: Parsed? = nil
        func flush() { if let c = current { out.append(c); current = nil } }
        for line in lines[bodyStart...] {
            if let c = parseCommentStart(line) {
                flush()
                current = c
            } else if var c = current, line.hasPrefix("  <!-- flamingo: "), line.hasSuffix(" -->"),
                      let data = String(line.dropFirst("  <!-- flamingo: ".count).dropLast(" -->".count)).data(using: .utf8),
                      let metadata = try? JSONDecoder().decode(CommentProvenance.self, from: data) {
                c.provenance = metadata
                current = c
            } else if var c = current, line.unicodeScalars.starts(with: "  ".unicodeScalars) {
                c.text += "\n" + String(String.UnicodeScalarView(line.unicodeScalars.dropFirst(2)))
                current = c
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func splitLines(_ text: String) -> [String] {
        var out: [String] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex, i = start
        while i < scalars.endIndex {
            if scalars[i] == "\n" { out.append(String(String.UnicodeScalarView(scalars[start..<i]))); i = scalars.index(after: i); start = i }
            else { i = scalars.index(after: i) }
        }
        out.append(String(String.UnicodeScalarView(scalars[start..<scalars.endIndex])))
        return out
    }

    static func parseCommentStart(_ line: String) -> Parsed? {
        let s = line.unicodeScalars
        guard s.starts(with: "- [".unicodeScalars) else { return nil }
        let tsStart = s.index(s.startIndex, offsetBy: 3)
        guard let close = s[tsStart...].firstIndex(of: "]") else { return nil }
        let ts = String(String.UnicodeScalarView(s[tsStart..<close]))
        guard SidecarFormat.timestamp(from: ts) != nil else { return nil }
        let rest = s[s.index(after: close)...]
        if rest.isEmpty { return Parsed(timestamp: ts, anchor: nil, text: "") }
        guard rest.first == " " else { return nil }
        let body = rest.dropFirst()
        if let (anchor, text) = parseAnchor(body) { return Parsed(timestamp: ts, anchor: anchor, text: text) }
        return Parsed(timestamp: ts, anchor: nil, text: String(String.UnicodeScalarView(body)))
    }

    static func parseAnchor(_ body: Substring.UnicodeScalarView) -> (FileAnchor, String)? {
        guard body.first == "(" else { return nil }
        let inner = body.dropFirst()
        guard let space = inner.firstIndex(of: " "), space > inner.startIndex,
              let kind = FileAnchor.Kind(rawValue: String(String.UnicodeScalarView(inner[..<space]))) else { return nil }
        let valueStart = inner.index(after: space)
        var from = valueStart
        while let close = inner[from...].firstIndex(of: ")") {
            let next = inner.index(after: close)
            let value = String(String.UnicodeScalarView(inner[valueStart..<close]))
            if next == inner.endIndex { return (FileAnchor(kind: kind, value: value), "") }
            if inner[next] == " " { return (FileAnchor(kind: kind, value: value), String(String.UnicodeScalarView(inner[inner.index(after: next)...]))) }
            from = next
        }
        return nil
    }
}

final class ObsidianReadabilityTests: XCTestCase {
    /// Thoughts of every shape: threads, intent, work, selections, multiline, unknown keys, non-JSON lines, AI replies.
    func richNote() -> String {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var cs: [Comment] = []
        cs.append(Comment(timestamp: t, anchor: FileAnchor(kind: .slide, value: "7"), text: "Pricing contradicts [[q3-model.xlsx]]. A --> B <tag>").stamped())
        var intent = Comment(timestamp: t.addingTimeInterval(60), text: "review conflict\nsecond line\n> Arc — $249 retail", provenance: nil,
                             meta: ThoughtMeta(uid: "t1234567ab", kind: .intent, kindBy: .model, state: .open, due: "2026-10-23",
                                               intent: ThoughtIntent(action: "review-conflict", objects: ["a.pptx#slide 7", "b.xlsx"], confidence: 0.9, model: "gemma3:4b", at: "2026-10-17 09:00")))
        intent.provenance = CommentProvenance(origin: .human, appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: "x --> y", sourceURL: "https://e.com/?a=1&b=2")
        cs.append(intent)
        cs.append(Comment(timestamp: t.addingTimeInterval(120), text: "reply", provenance: CommentProvenance(origin: .ai, model: "qwen"),
                          meta: ThoughtMeta(uid: "t7654321cd", parent: "t1234567ab", work: "work/2026-10-17/x.md")))
        var doc = SidecarDocument(target: FileRef(relativePath: "decks/a.pptx"), id: UUID(), comments: cs)
        // (A hand-written non-JSON hidden line was text to older builds too, so it is not part of this proof.)
        doc.append(Comment(timestamp: t.addingTimeInterval(180), text: "done one", provenance: nil, meta: ThoughtMeta(state: .done, stateAt: "2026-10-17 10:00")))
        return SidecarFormat.render(doc)
    }

    func testEveryBodyLineIsABulletAContinuationOrAHiddenComment() throws {
        let text = richNote()
        var lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.removeLast(), "")
        let close = try XCTUnwrap(lines[1...].firstIndex(of: "---"))
        for line in lines[(close + 1)...] {
            let ok = line.hasPrefix("- [") || line.hasPrefix("  ")
            XCTAssertTrue(ok, "unexpected line: \(line)")
            if line.hasPrefix("  <!-- flamingo: ") {
                XCTAssertTrue(line.hasSuffix(" -->"))
                let inner = line.dropFirst("  <!-- flamingo: ".count).dropLast(" -->".count)
                XCTAssertFalse(inner.contains("-->"), "metadata could close its own comment")
                XCTAssertFalse(inner.contains(">"), "> is escaped")
                if let data = inner.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    XCTAssertNotNil(object["origin"], "older builds need origin to keep the line out of the text")
                }
            }
        }
    }

    func testRemovingTheHiddenLinesLeavesExactlyTheV1Rendering() {
        let text = richNote()
        let visible = text.components(separatedBy: "\n").filter { !$0.hasPrefix("  <!-- flamingo: ") }.joined(separator: "\n")
        var plain = SidecarFormat.parseDocument(text)
        var stripped: [Comment] = []
        for c in plain.comments { stripped.append(Comment(id: c.id, timestamp: c.timestamp, anchor: c.anchor, text: c.text)) }
        plain = SidecarDocument(frontmatter: plain.frontmatter, items: stripped.map(SidecarDocument.Item.comment))
        XCTAssertEqual(SidecarFormat.render(plain), visible)
    }

    func testAnOlderBuildReadsAV2NoteWithNothingLeakingIntoText() {
        let text = richNote()
        let old = FrozenV1Parser.parse(text)
        let new = SidecarFormat.parseDocument(text).comments
        XCTAssertEqual(old.count, new.count)
        for (o, n) in zip(old, new) {
            XCTAssertEqual(o.text, n.text, "an older build's thought text matches this build's")
            XCTAssertFalse(o.text.contains("flamingo:"))
            XCTAssertFalse(o.text.contains("\"uid\""))
            XCTAssertEqual(o.anchor, n.anchor)
            XCTAssertEqual(o.timestamp, SidecarFormat.string(fromTimestamp: n.timestamp))
        }
        // It sees provenance only (that is all it knows), and everything has some.
        XCTAssertEqual(old[0].provenance?.origin, .human)
        XCTAssertEqual(old[2].provenance?.origin, .ai)
        XCTAssertEqual(old[2].provenance?.model, "qwen")
    }

    func testTheDesignExampleReadsCleanlyInTheFrozenParser() {
        let parsed = FrozenV1Parser.parse(SidecarV2Tests.v2Note)
        XCTAssertEqual(parsed.map(\.text), [
            "Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229.",
            "review conflict between this and [[q3-model.xlsx]] before friday",
            "Conflict. Slide 7 prices Arc at $249; [[q3-model.xlsx#cell Revenue!C12]] still multiplies by $229.",
            "Fixed the model; deck stays at $249",
        ])
    }

    /// The old bug, pinned: a metadata line without `origin` is text to the frozen parser. That
    /// is why this build always writes `origin`.
    func testWithoutOriginAnOlderBuildWouldLeakTheLine() {
        let leaky = "- [2026-10-17 09:05] Thought\n  <!-- flamingo: {\"uid\":\"t1111111aa\"} -->\n"
        XCTAssertTrue(FrozenV1Parser.parse(leaky)[0].text.contains("uid"))
        var doc = SidecarFormat.parseDocument(leaky)
        XCTAssertEqual(doc.comments[0].text, "Thought")
        XCTAssertEqual(FrozenV1Parser.parse(SidecarFormat.render(doc))[0].text, "Thought")
        doc.normalize()
    }
}
