import Foundation
import FlamingoCore
import FlamingoExtract

public struct IndexedFileCoverage: Sendable, Equatable {
    public var file: FileRef
    public var coverage: ExtractionCoverage
    public var attemptedAt: Date?
    public var retryAfter: Date?
    public var attemptCount: Int
}

public struct IndexHealth: Sendable, Equatable {
    public var files: Int
    public var complete: Int
    public var partial: Int
    public var failed: Int
    public var metadataOnly: Int
    public var unsupported: Int
    public var retryable: Int { partial + failed }
}

extension IndexStore {
    public func health() throws -> IndexHealth {
        let rows = try read { db in
            try db.query("SELECT extraction_state, count(*) FROM files GROUP BY extraction_state") { ($0.string(0), $0.int(1)) }
        }
        let counts = Dictionary(rows, uniquingKeysWith: +)
        return IndexHealth(files: counts.values.reduce(0, +), complete: counts["complete", default: 0],
                           partial: counts["partial", default: 0], failed: counts["failed", default: 0],
                           metadataOnly: counts["metadataOnly", default: 0], unsupported: counts["unsupported", default: 0])
    }

    public func coverage(for ref: FileRef) throws -> IndexedFileCoverage? {
        try read { db in
            try db.query("SELECT path, extraction_state, extraction_reason, processed_units, total_units, attempted_at, retry_after, attempt_count FROM files WHERE path = ?", ref.relativePath) { Self.coverageRow($0) }.first
        }
    }

    /// Files that need attention, bounded and suitable for a health panel.
    public func incompleteFiles(limit: Int = 100) throws -> [IndexedFileCoverage] {
        try read { db in
            try db.query("SELECT path, extraction_state, extraction_reason, processed_units, total_units, attempted_at, retry_after, attempt_count FROM files WHERE extraction_state != 'complete' ORDER BY extraction_state, path LIMIT ?", max(0, limit)) { Self.coverageRow($0) }
        }
    }

    /// Explicit user retry, including failed and partial reads, without re-extracting healthy files.
    public func retryFailed(limit: Int = 200, shouldCancel: () -> Bool = { false }) throws {
        let refs = try read { db in
            try db.query("SELECT path FROM files WHERE extraction_state IN ('failed', 'partial') ORDER BY attempted_at, path LIMIT ?", max(0, limit)) { FileRef(relativePath: $0.string(0)) }
        }
        try update(refs, force: true, shouldCancel: shouldCancel)
    }

    /// Continues bounded PDF passes and due failures. The caller controls lifecycle cancellation.
    /// Text-budget truncation has no retry timestamp and remains visible for manual review.
    @discardableResult
    public func resumePendingExtractions(maxPasses: Int = 8, shouldCancel: () -> Bool = { false }) throws -> Int {
        var attempts = 0
        for _ in 0..<max(0, maxPasses) {
            guard !shouldCancel() else { break }
            let refs = try read { db in
                try db.query("SELECT path FROM files WHERE retry_after <= ? ORDER BY attempted_at LIMIT ?", Date().timeIntervalSince1970, Self.batchSize) { FileRef(relativePath: $0.string(0)) }
            }
            guard !refs.isEmpty else { break }
            try update(refs, force: true, shouldCancel: shouldCancel)
            attempts += refs.count
        }
        return attempts
    }

    /// Explicit metadata indexing for a caller that cannot open the source. Normal update()
    /// automatically applies size and cloud-placeholder eligibility too.
    public func updateMetadata(_ refs: [FileRef], reason: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        let rules = PathRules(vault: vault)
        try writer.transaction {
            for ref in Set(refs) where rules.admits(ref.relativePath, isDirectory: false) {
                let url = vault.url(for: ref)
                guard let stamp = Stamp(url: url) else { continue }
                var value = Extracted.empty
                value.coverage = ExtractionCoverage(.metadataOnly, reason: reason)
                try write(Extraction(ref: ref, stamp: stamp, id: (try? FileIdentity.existingID(for: url))?.uuidString, extracted: value))
            }
        }
        invalidateCaches()
    }

    func recordCoverage(_ value: ExtractionCoverage, path: String, priorAttempts: Int) throws {
        let now = Date().timeIntervalSince1970
        let attempts = value.state == .complete ? 0 : priorAttempts + 1
        let next: Double?
        if value.state == .failed {
            next = now + min(3600, 30 * pow(2, Double(min(attempts - 1, 7))))
        } else if value.state == .partial, let processed = value.processedUnits, let total = value.totalUnits,
                  processed < total, value.reason?.contains("text budget") != true {
            // Ready for another explicitly bounded pass; no sleeps or unowned background loop.
            next = now
        } else { next = nil }
        try writer.run("UPDATE files SET extraction_state = ?, extraction_reason = ?, attempted_at = ?, retry_after = ?, attempt_count = ?, processed_units = ?, total_units = ? WHERE path = ?",
                       value.state.rawValue, value.reason, now, next, attempts, value.processedUnits, value.totalUnits, path)
    }

    private static func coverageRow(_ row: Row) -> IndexedFileCoverage {
        IndexedFileCoverage(file: FileRef(relativePath: row.string(0)),
                            coverage: ExtractionCoverage(ExtractionCoverage.State(rawValue: row.string(1)) ?? .failed,
                                                         reason: row.optionalString(2), processedUnits: row.isNull(3) ? nil : row.int(3),
                                                         totalUnits: row.isNull(4) ? nil : row.int(4)),
                            attemptedAt: row.isNull(5) ? nil : Date(timeIntervalSince1970: row.double(5)),
                            retryAfter: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.double(6)), attemptCount: row.int(7))
    }
}
