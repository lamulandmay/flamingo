import XCTest
import SwiftUI
import AppKit
@testable import FlamingoCapture
import FlamingoCore
import FlamingoDesign

/// Renders the style guide and a rail with a thread fixture to PNG, light and dark, when
/// `FLAMINGO_SNAPSHOT_DIR` names a folder. Without it the tests only check that rendering works.
@MainActor
final class RailSnapshotTests: XCTestCase {
    private var outputDir: URL? { ProcessInfo.processInfo.environment["FLAMINGO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    private func render<V: View>(_ view: V, size: CGSize?, dark: Bool, name: String) throws {
        let scheme: ColorScheme = dark ? .dark : .light
        let root = view.environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        let fit = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fit)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 10)
        guard let dir = outputDir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    static func fixture(now: Date = Date()) -> (comments: [Comment], pending: [String: String]) {
        func at(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func stamp(_ days: Int) -> String { ThoughtDates.string(from: Calendar.current.date(byAdding: .day, value: days, to: now)!, hasTime: false) }
        var root = Comment(timestamp: at(52), anchor: FileAnchor(kind: .slide, value: "7"), text: "Pricing on this slide contradicts the Q3 model")
        root.meta = ThoughtMeta(uid: "t0000root1")
        var ai = Comment(timestamp: at(51), text: "Slide 7 says $42 per seat; [[q3-model.xlsx#cell Pricing!B12]] has $39.",
                         provenance: CommentProvenance(origin: .ai, model: "qwen3-8b"))
        ai.meta = ThoughtMeta(uid: "t0000ai001", parent: "t0000root1")
        var human = Comment(timestamp: at(49), text: "Right, the model is newer. Fix the deck.")
        human.meta = ThoughtMeta(uid: "t0000hum01", parent: "t0000ai001")
        var done = Comment(timestamp: at(30), text: "Send the corrected deck to Mara")
        done.meta = ThoughtMeta(uid: "t0000done1", state: .done, stateAt: "2026-10-16 09:00")
        var question = Comment(timestamp: at(5), text: "Which version did legal approve?")
        question.meta = ThoughtMeta(uid: "t0000ques1", due: stamp(2))
        var later = Comment(timestamp: at(2), text: "Check the licensing terms for the stock photos")
        later.meta = ThoughtMeta(uid: "t0000todo1", due: stamp(12))
        let idea = Comment(timestamp: at(1), text: "Maybe the board deck should open with the churn story")
        return ([root, ai, human, done, question, later, idea], ["t0000ques1": "Legal approved version 3 on Oct 9, according to"])
    }

    private func rail(dark: Bool) -> some View {
        let f = Self.fixture()
        return CommentsRail(comments: f.comments, onJump: { _ in }, onEdit: { _ in }, onDelete: { _ in })
            .onReply { _ in }
            .onSetState { _, _, _ in }
            .pendingReplies(f.pending)
            .focusComment(f.comments[1].id)
            .frame(width: Theme.Size.rail + 40, height: 600)
            .background(Theme.Color.bg)
    }

    func testRailThreadFixture() throws {
        for dark in [false, true] { try render(rail(dark: dark), size: CGSize(width: Theme.Size.rail + 40, height: 600), dark: dark, name: "rail") }
    }

    func testDesignPreview() throws {
        for dark in [false, true] {
            try render(DesignPreview(), size: nil, dark: dark, name: "design-preview")
        }
    }

    func testEchoRows() throws {
        let model = ThoughtEchoModel()
        let hits = [
            EchoHit(uid: "a", file: FileRef(relativePath: "decks/q3.pptx"), firstLine: "Why did margin drop in Q3?", kind: .question, date: Date().addingTimeInterval(-9 * 86_400)),
            EchoHit(uid: "b", file: FileRef(relativePath: "finance/q3-model.xlsx"), firstLine: "Send the margin bridge to Mara", kind: .todo, state: .done, date: Date().addingTimeInterval(-40 * 86_400)),
        ]
        model.setHitsForPreview(hits)
        let view = VStack(alignment: .leading, spacing: 0) {
            ThoughtEcho(model: model, onJump: { _ in })
            Text("Margin fell again because").font(Theme.Font.body).foregroundStyle(Theme.Color.text).padding(Theme.Space.s)
        }
        .frame(width: Theme.Size.panel)
        .background(Theme.Color.bg)
        for dark in [false, true] { try render(view, size: nil, dark: dark, name: "echo") }
    }
}
