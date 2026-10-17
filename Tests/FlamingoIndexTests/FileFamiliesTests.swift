import XCTest
import Darwin
@testable import FlamingoIndex
import FlamingoCore

final class FileFamiliesTests: IndexTestCase {
    func testDifferentNamesAndExtensionsCanBeProvenByteDuplicates() throws {
        let selected = try write("work/Orchid analysis.fltest", deck)
        let downloaded = try write("Downloads/98172.bin", deck)
        try write("elsewhere/Orchid analysis v2.fltest", deck + "An additional correction.")
        try store.reindex()
        let family = try store.fileFamily(for: selected)
        let duplicate = try XCTUnwrap(family.members.first { $0.file == downloaded })
        XCTAssertEqual(duplicate.kind, .identicalCopy)
        XCTAssertTrue(duplicate.reason.contains("SHA-256"))
        XCTAssertEqual(duplicate.kind.label, "Identical copy")
        XCTAssertEqual(try String(contentsOf: vault.url(for: selected)), deck)
    }

    func testNameVariantsAcrossFoldersKeepRealComparisonAnchors() throws {
        let selected = try write("work/Orchid budget v3.fltest", """
        == slide 1: Overview
        The Orchid budget covers venue costs and equipment purchases.
        == slide 7: Revised chart
        Equipment costs are now 28400 instead of 27100.
        """)
        let older = try write("Downloads/Orchid budget final (2).fltest", """
        == page 1: Overview
        The Orchid budget covers venue costs and equipment purchases.
        == page 2: Old chart
        Equipment costs are now 27100 instead of 26100.
        """)
        try store.reindex()
        let member = try XCTUnwrap(try store.fileFamily(for: selected).members.first { $0.file == older })
        XCTAssertEqual(member.kind, .possibleVersion)
        XCTAssertFalse(member.reason.localizedCaseInsensitiveContains("newest"))
        let comparison = try XCTUnwrap(member.comparison)
        XCTAssertEqual(comparison.sharedSections, 1)
        XCTAssertEqual(comparison.selectedOnly.first?.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(comparison.candidateOnly.first?.anchor, FileAnchor(kind: .page, value: "2"))
        XCTAssertTrue(comparison.selectedOnly.first?.excerpt.contains("28400") == true)
        XCTAssertTrue(comparison.scope.contains("images, charts"))
        XCTAssertFalse(comparison.partial)
    }

    func testGenericNamesAreNotSufficientEvidenceAndNumbersStayMeaningful() throws {
        let report = try write("one/Report.fltest", "Completely unrelated alpha evidence.")
        try write("two/Report final.fltest", "Completely unrelated beta results and conclusions.")
        try write("two/Report v2.fltest", "A different science experiment.")
        let chapter = try write("book/Chapter 2.fltest", "The chapter about a medieval kingdom.")
        try write("book/Chapter 3.fltest", "A chapter about the industrial revolution.")
        try store.reindex()
        XCTAssertTrue(try store.fileFamily(for: report).members.isEmpty)
        XCTAssertTrue(try store.fileFamily(for: chapter).members.isEmpty)
        XCTAssertEqual(FamilyName("Orchid budget final v3 (2)").normalized, "orchid budget")
        XCTAssertEqual(FamilyName("Experiment 23 revised").normalized, "experiment 23")
        XCTAssertTrue(FamilyName("Orchid").matches(FamilyName("Orchid v2")))
        XCTAssertTrue(FamilyName("Q3 budget").matches(FamilyName("Q3 budget final")))
        XCTAssertFalse(FamilyName("Q3 budget").matches(FamilyName("Q4 budget final")))
    }

    func testDifferentNamesAndFormatsRequireSubstantialContentOverlap() throws {
        let body = "The Orchid project measured equipment expenditure across twelve laboratory groups during the spring term. Each group recorded purchase dates, supplier invoices, instrument categories, and delivery locations. The final analysis reconciled those records against departmental approvals and identified three outstanding payments requiring further investigation."
        let selected = try write("drafts/Orchid research.fltest", "== slide 7: Analysis\n" + body)
        let renamed = try write("Downloads/meeting-handout.md", "== page 2: Findings\n" + body + "\nPrepared for the research meeting.")
        let boilerplate = try write("other/Unrelated paper.md", "== page 1: Introduction\nThe final analysis reconciled those records against departmental approvals. Unrelated botanical observations examined leaf structure, chlorophyll concentrations, stem growth and seasonal rainfall over decades of agricultural field experiments.")
        try store.reindex()
        let family = try store.fileFamily(for: selected)
        let related = try XCTUnwrap(family.members.first { $0.file == renamed })
        XCTAssertEqual(related.kind, .relatedContent)
        XCTAssertEqual(related.anchor, FileAnchor(kind: .page, value: "2"))
        XCTAssertFalse(family.members.contains { $0.file == boilerplate })
        XCTAssertEqual(related.comparison?.sharedSections, 1)
    }

    func testManyMatchingSectionsCannotCrowdOtherFilesOutOfCandidates() throws {
        let body = "The calibration protocol measures instrument sensitivity across twelve laboratory stations during controlled experiments. Researchers recorded temperature readings, measurement intervals, equipment identifiers, and environmental conditions. Statistical analysis reconciled those observations against reference standards and identified three systematic discrepancies requiring independent verification before publication."
        let selected = try write("source.fltest", "== slide 4: Experiment\n" + body)
        let repeated = (1...(IndexStore.familyCandidateLimit + 12)).map {
            "== slide \($0): Experiment\n" + body
        }.joined(separator: "\n")
        try write("archive.fltest", repeated)
        let other = try write("renamed-handout.md", "== page 9: Experiment\n" + body + "\nThis handout includes additional explanatory remarks prepared for discussion at the upcoming departmental meeting.")
        try store.reindex()
        let family = try store.fileFamily(for: selected)
        XCTAssertEqual(family.members.first { $0.file == other }?.kind, .relatedContent,
                       "The candidate limit must count files, not repeated matching sections.")
        XCTAssertFalse(family.truncated, "Three files should not exhaust the candidate-file bound.")
    }

    func testHashCacheRechecksChangedFileEvenWhenMtimeAndLengthArePreserved() throws {
        let selected = try write("selected.fltest", "Identical bytes originally.")
        let other = try write("unrelated.fltest", "Identical bytes originally.")
        try store.reindex()
        XCTAssertEqual(try store.fileFamily(for: selected).members.first?.kind, .identicalCopy)
        let url = vault.url(for: other)
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let different = "Different bytes originally."
        XCTAssertEqual(different.utf8.count, "Identical bytes originally.".utf8.count)
        try different.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        XCTAssertTrue(try store.fileFamily(for: selected).members.isEmpty, "Cached hashes must not survive source replacement.")
    }

    func testChangedIndexDoesNotSupplyStaleTextComparison() throws {
        let selected = try write("Orchid budget.fltest", deck)
        let candidate = try write("Orchid budget v2.fltest", deck + "\nAnother section")
        try store.reindex()
        XCTAssertNotNil(try store.fileFamily(for: selected).members.first?.comparison)
        try write(selected.relativePath, "Completely replaced and pending reindex.")
        let family = try store.fileFamily(for: selected)
        XCTAssertEqual(family.members.first?.file, candidate)
        XCTAssertNil(family.members.first?.comparison)
        XCTAssertTrue(family.notes.contains { $0.contains("changed since indexing") })
        try store.update([selected])
        XCTAssertNotNil(try store.fileFamily(for: selected).members.first?.comparison)
    }

    func testPartialExtractionNeverClaimsCompleteDocumentEquality() throws {
        let selected = try write("Orchid budget.fltest", deck)
        let candidate = try write("Orchid budget v2.fltest", deck + "\nAdditional content")
        try store.reindex()
        try store.writer.run("UPDATE files SET extraction_state = 'partial', extraction_reason = 'text budget' WHERE path = ?", candidate.relativePath)
        let comparison = try XCTUnwrap(try store.fileFamily(for: selected).members.first?.comparison)
        XCTAssertTrue(comparison.partial)
        XCTAssertTrue(comparison.scope.contains("partial extraction"))
        XCTAssertTrue(comparison.scope.contains("may still be present"))
    }

    func testMissingUnreadableAndSymbolicLinkSourcesAreSkipped() throws {
        let selected = try write("Orchid budget.fltest", deck)
        let unreadable = try write("Orchid budget v2.fltest", deck)
        let linked = try write("Orchid budget v3.fltest", deck)
        let gone = try write("Orchid budget v4.fltest", deck)
        try store.reindex()
        let unreadableURL = vault.url(for: unreadable)
        XCTAssertEqual(chmod(unreadableURL.path, 0), 0)
        defer { _ = chmod(unreadableURL.path, 0o600) }
        try FileManager.default.removeItem(at: vault.url(for: linked))
        try FileManager.default.createSymbolicLink(at: vault.url(for: linked), withDestinationURL: vault.url(for: selected))
        try FileManager.default.removeItem(at: vault.url(for: gone))
        let family = try store.fileFamily(for: selected)
        XCTAssertTrue(family.members.isEmpty)
        XCTAssertTrue(family.notes.contains { $0.contains("sources were skipped") })
        XCTAssertTrue(try store.fileFamily(for: linked).members.isEmpty)
    }

    func testCandidateAndResultBoundsAndCancellation() throws {
        let selected = try write("unrelated-selected.fltest", "same")
        for i in 0..<(IndexStore.familyCandidateLimit + 10) { try write("copies/\(i).fltest", "same") }
        try store.reindex()
        let result = try store.fileFamily(for: selected, limit: 3)
        XCTAssertEqual(result.members.count, 3)
        XCTAssertTrue(result.members.allSatisfy { $0.kind == .identicalCopy })
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.notes.isEmpty)
        XCTAssertEqual(try store.fileFamily(for: selected, limit: 0), ArtifactFamilySnapshot(selected: selected))
        XCTAssertThrowsError(try store.fileFamily(for: selected, checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var calls = 0
        XCTAssertThrowsError(try store.fileFamily(for: selected, checkCancellation: {
            calls += 1
            if calls > 30 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testLargeSparseFilesAreNotReadToFindDuplicates() throws {
        let selected = try write("Orchid footage.raw", "")
        let candidate = try write("Orchid footage copy.raw", "")
        for ref in [selected, candidate] {
            let handle = try FileHandle(forWritingTo: vault.url(for: ref))
            try handle.truncate(atOffset: UInt64(VaultScanner.limits.maxExtractableBytes + 1))
            try handle.close()
        }
        try store.updateMetadata([selected, candidate], reason: "Above extraction limit")
        let result = try store.fileFamily(for: selected)
        XCTAssertEqual(result.members.first?.kind, .possibleVersion)
        XCTAssertNil(result.members.first?.comparison)
        XCTAssertTrue(result.notes.contains { $0.contains("byte comparisons were skipped") })
    }

    func testCloudPlaceholderAndNonRegularMetadataAreRejectedBeforeReading() throws {
        var metadata = stat()
        metadata.st_mode = mode_t(S_IFREG | 0o644)
        metadata.st_size = 100
        XCTAssertNotNil(FamilyStamp(metadata))
        metadata.st_flags = UInt32(SF_DATALESS)
        XCTAssertNil(FamilyStamp(metadata), "Opening a dataless placeholder would download its source.")
        metadata.st_flags = 0
        metadata.st_mode = mode_t(S_IFLNK | 0o644)
        XCTAssertNil(FamilyStamp(metadata))
        metadata.st_mode = mode_t(S_IFIFO | 0o644)
        XCTAssertNil(FamilyStamp(metadata), "A named pipe must never be opened for hashing.")
    }
}
