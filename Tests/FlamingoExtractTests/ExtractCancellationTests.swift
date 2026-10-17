import XCTest
@testable import FlamingoExtract

final class ExtractCancellationTests: XCTestCase {
    func testCancelledTaskSkipsQueuedExtraction() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { () -> Result<Extracted, Error> in
            while !Task.isCancelled { await Task.yield() }
            do { return .success(try await Extract.extractInBackground(url)) } catch { return .failure(error) }
        }
        task.cancel()
        switch await task.value {
        case .success: XCTFail("a task cancelled before its turn should not extract")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let text = try await Extract.extractInBackground(url).text
        XCTAssertTrue(text.contains("hello"))
    }
}
