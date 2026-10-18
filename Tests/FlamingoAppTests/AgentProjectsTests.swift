import AppKit
import SwiftUI
import XCTest
import FlamingoCore
import FlamingoAgents
import FlamingoDesign
@testable import Flamingo

/// Plan 18 in the app: the dot, No, Make Project with one undo, and ⌘N's Project kind.
@MainActor
final class AgentProjectsTests: XCTestCase {
    private func withState(_ body: (AppState, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("Flamingo-AgentProjectsTests-" + UUID().uuidString)
        try fm.createDirectory(at: made.appendingPathComponent("code/lamp/Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: made.appendingPathComponent("code/ledger"), withIntermediateDirectories: true)
        try Data("Use tabs.\n".utf8).write(to: made.appendingPathComponent("code/lamp/CLAUDE.md"))
        try Data("See [readme](README.md).\n".utf8).write(to: made.appendingPathComponent("code/lamp/NOTES.md"))
        try Data("# Lamp\n".utf8).write(to: made.appendingPathComponent("code/lamp/README.md"))
        try Data("print(1)\n".utf8).write(to: made.appendingPathComponent("code/lamp/Sources/main.swift"))
        let root = URL(fileURLWithPath: ProjectResolver.canonical(made.path), isDirectory: true)
        let keys = ["lastVault", "recentVaults"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        let state = AppState(); state.open(root); state.session?.stop()
        // Agents "work" in lamp and ledger; the real scan would ignore a temporary folder.
        state.agentProjects.find = { vault, declined, _ in
            ["code/lamp", "code/ledger"].compactMap { path in
                let folder = vault.root.appendingPathComponent(path, isDirectory: true)
                guard !declined.contains(path), !AgentPresence.isProject(folder) else { return nil }
                let activity = AgentActivity(project: folder, harness: .claudeCode, session: "s1", title: "Sort menu",
                                             lastActive: Date(), isLive: true)
                return ProjectOffer(root: folder, activity: [activity])
            }
        }
        defer {
            state.selected = nil
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for prefix in ["workspace.", "vault.selected.", "vault.expanded.", "vault.foldedBookmarks."] {
                UserDefaults.standard.removeObject(forKey: prefix + root.path)
            }
            try? fm.removeItem(at: made)
        }
        try await body(state, root)
    }

    private func tree(_ root: URL) throws -> [String: Data?] {
        var out: [String: Data?] = [:]
        let base = root.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            out.updateValue(isDir ? nil : try Data(contentsOf: url), forKey: path)
        }
        return out
    }

    func testTheDotMarksEachOfferAndTheFoldersAboveIt() async throws {
        try await withState { state, _ in
            let model = state.agentProjects
            await model.refresh()?.value
            XCTAssertEqual(model.dotted, ["code", "code/lamp", "code/ledger"])
            XCTAssertEqual(model.offer(under: "code").map { model.relativePath($0.root) }, "code/lamp")
        }
    }

    func testNoIsRememberedAndTheDotGoes() async throws {
        try await withState { state, root in
            let model = state.agentProjects
            await model.refresh()?.value
            model.present(root.appendingPathComponent("code/ledger", isDirectory: true))
            XCTAssertNotNil(model.sheet)
            model.decline(root.appendingPathComponent("code/ledger", isDirectory: true))
            XCTAssertNil(model.sheet)
            XCTAssertEqual(model.dotted, ["code", "code/lamp"])
            await model.refresh()?.value
            XCTAssertEqual(model.dotted, ["code", "code/lamp"])
            XCTAssertEqual(ProjectsStore(vault: Vault(root: root)).declined(), ["code/ledger"])
        }
    }

    func testMakeProjectConvertsTheFolderAndOneUndoTakesItBack() async throws {
        try await withState { state, root in
            let model = state.agentProjects
            let lamp = root.appendingPathComponent("code/lamp", isDirectory: true)
            await model.refresh()?.value
            let before = try tree(lamp)
            model.present(lamp)
            XCTAssertEqual(model.sheet?.plan.moves, ["NOTES.md": "docs/NOTES.md"])
            model.make(lamp)
            XCTAssertNil(model.sheet)
            XCTAssertEqual(ProjectChecker.check(root: lamp).issues, [])
            XCTAssertEqual(try String(contentsOf: lamp.appendingPathComponent("docs/NOTES.md"), encoding: .utf8), "See [readme](../README.md).\n")
            XCTAssertTrue(try String(contentsOf: lamp.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("## Rules\n\nUse tabs.\n"))
            XCTAssertEqual(model.dotted, ["code", "code/ledger"])

            XCTAssertEqual(state.actionHistory.undoActionName, "Make Project")
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try tree(lamp), before)
            XCTAssertTrue(try state.actionHistory.redo())
            XCTAssertEqual(ProjectChecker.check(root: lamp).issues, [])
        }
    }

    func testNewProjectMakesAStructuredFolderAndOpensAgentsFile() async throws {
        try await withState { state, root in
            let code = root.appendingPathComponent("code", isDirectory: true)
            try state.agentProjects.createProject(named: "Kiln", in: code)
            let kiln = code.appendingPathComponent("Kiln", isDirectory: true)
            let report = ProjectChecker.check(root: kiln)
            XCTAssertTrue(report.isStructured)
            XCTAssertEqual(report.issues, [])
            XCTAssertEqual(state.selected?.relativePath, "code/Kiln/AGENTS.md")
            XCTAssertEqual(state.actionHistory.undoActionName, "New Project")
            // A second one with the same name gets a number, as New Folder does.
            try state.agentProjects.createProject(named: "Kiln", in: code)
            XCTAssertTrue(AgentPresence.isProject(code.appendingPathComponent("Kiln 1", isDirectory: true)))
        }
    }

    // MARK: Offscreen renders, for looking at (FLAMINGO_SNAPSHOT_DIR=<folder> to keep them)

    func testRenderTheSheetAndTheDot() async throws {
        try await withState { state, root in
            let model = state.agentProjects
            await model.refresh()?.value
            model.present(root.appendingPathComponent("code/lamp", isDirectory: true))
            let sheet = try XCTUnwrap(model.sheet)
            // Any folder, planned but never converted: FLAMINGO_SNAPSHOT_PROJECT=<folder>.
            if let other = ProcessInfo.processInfo.environment["FLAMINGO_SNAPSHOT_PROJECT"] {
                let root = URL(fileURLWithPath: other, isDirectory: true)
                let big = AgentProjectsModel.Sheet(root: root, plan: ProjectConverter.plan(root: root), activity: sheet.activity)
                try keep(try render(MakeProjectSheet(model: model, sheet: big), width: 520, appearance: .darkAqua), "make-project-sheet-big.png")
            }
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let png = try render(MakeProjectSheet(model: model, sheet: sheet), width: 520, appearance: appearance)
                try keep(png, "make-project-sheet-\(name).png")
                let row = HStack(spacing: Theme.Space.s) {
                    FolderGlyph()
                    Text("lamp").font(Theme.Font.body).foregroundStyle(Theme.Color.text)
                    Spacer()
                    AgentDot(model: model, path: "code/lamp")
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(width: 240, height: Theme.Size.row)
                .background(Theme.Color.bg)
                try keep(try render(row, width: 240, appearance: appearance), "agent-dot-row-\(name).png")
            }
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name) throws -> Data {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(NSSize(width: width, height: max(size.height, 20)))
        host.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func keep(_ png: Data, _ name: String) throws {
        XCTAssertGreaterThan(png.count, 1000)
        guard let dir = ProcessInfo.processInfo.environment["FLAMINGO_SNAPSHOT_DIR"] else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
