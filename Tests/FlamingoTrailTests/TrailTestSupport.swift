import XCTest
import FlamingoCore
@testable import FlamingoTrail

/// 2026-10-14T20:05:12Z. Every synthetic stream is laid out relative to this.
let trailBase = Date(timeIntervalSince1970: 1_792_008_312)

func ref(_ path: String) -> FileRef { FileRef(relativePath: path) }

/// A synthetic event `seconds` after `trailBase`.
func ev(_ kind: TrailEvent.Kind, _ seconds: TimeInterval, file: String? = nil, text: String? = nil,
        anchor: FileAnchor? = nil, id: UUID = UUID(), base: Date = trailBase) -> TrailEvent {
    TrailEvent(id: id, at: base.addingTimeInterval(seconds), kind: kind,
               file: file.map(ref), anchor: anchor, text: text)
}

/// Opens `paths` one after another, `step` seconds apart, starting at `start`.
func opens(_ paths: [String], from start: TimeInterval = 0, step: TimeInterval = 10, base: Date = trailBase) -> [TrailEvent] {
    paths.enumerated().map { ev(.opened, start + Double($0.offset) * step, file: $0.element, base: base) }
}

func paths(_ files: [FileRef]) -> [String] { files.map(\.relativePath) }

/// A throwaway vault on disk plus a store over it. Restores the privacy switch afterwards.
class TrailStoreTestCase: XCTestCase {
    var root: URL!
    var vault: Vault!
    private var savedEnabled: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamingo-trail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(root: root)
        savedEnabled = UserDefaults.standard.object(forKey: TrailStore.enabledDefaultsKey)
        TrailStore.isEnabled = true
    }

    override func tearDownWithError() throws {
        if let savedEnabled {
            UserDefaults.standard.set(savedEnabled, forKey: TrailStore.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TrailStore.enabledDefaultsKey)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// A store that never flushes on its own during a test, so flushing is explicit.
    func makeStore() -> TrailStore {
        let s = TrailStore(vault: vault)
        s.flushDelay = 3600
        return s
    }

    func fileText(_ store: TrailStore) throws -> String {
        String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
    }

    func fileLines(_ store: TrailStore) throws -> [String] {
        try fileText(store).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func writeTrailFile(_ text: String) throws {
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: vault.stateDir.appendingPathComponent("trail.jsonl"))
    }

    func appendRaw(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    func touch(_ relativePath: String) throws {
        let url = vault.url(for: ref(relativePath))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
}
