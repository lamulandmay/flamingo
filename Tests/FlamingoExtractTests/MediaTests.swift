import XCTest
import AVFoundation
import CoreMedia
@testable import FlamingoExtract

final class MediaTests: XCTestCase {
    func testClipMetadataAndChapters() throws {
        let e = try MediaExtractor().extract(Fixtures.url("clip.m4a"))
        XCTAssertEqual(e.title, "Flamingo Field Notes")
        XCTAssertEqual(e.text, """
            Flamingo Field Notes
            Ada Marsh
            Lagoon Recordings
            Notes spoken at the salt lagoon
            Recorded at dawn
            Pink birds in shallow water
            Arrival
            The Lagoon
            Departure
            """)
        XCTAssertEqual(e.sections.map(\.anchor.rendered), ["(time 0:00)", "(time 0:01)", "(time 0:02)"])
        XCTAssertEqual(e.sections.map(\.title), ["Arrival", "The Lagoon", "Departure"])
        XCTAssertEqual(e.sections.map(\.text), ["Arrival", "The Lagoon", "Departure"])
    }

    func testTimecodeSwitchesToHoursAtOneHour() {
        XCTAssertEqual(MediaExtractor.timecode(0), "0:00")
        XCTAssertEqual(MediaExtractor.timecode(59), "0:59")
        XCTAssertEqual(MediaExtractor.timecode(59.9), "0:59")
        XCTAssertEqual(MediaExtractor.timecode(754), "12:34")
        XCTAssertEqual(MediaExtractor.timecode(3599), "59:59")
        XCTAssertEqual(MediaExtractor.timecode(3600), "1:00:00")
        XCTAssertEqual(MediaExtractor.timecode(3725), "1:02:05")
        XCTAssertEqual(MediaExtractor.timecode(.nan), "0:00")
    }

    func testMP3CommentsSkipITunesBlobs() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("tagged.mp3")
        try Self.mp3(frames: [("TIT2", "Salt Flats"), ("TPE1", "Ada Marsh"),
                              ("COMM", "iTunNORM\0 00000A3B 000009F1 0000453E 00003E2C 0002257D 0002257D"),
                              ("COMM", "\0Recorded live")]).write(to: f)
        let e = try MediaExtractor().extract(f)
        XCTAssertEqual(e.title, "Salt Flats")
        XCTAssertEqual(e.text, "Salt Flats\nAda Marsh\nRecorded live")
    }

    func testMediaWithoutMetadataIsEmpty() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
        buffer.frameLength = 4000
        try AVAudioFile(forWriting: f, settings: format.settings).write(from: buffer)
        XCTAssertEqual(try MediaExtractor().extract(f), Extracted(text: ""))
    }

    func testCorruptAndTruncatedMediaThrowMalformed() throws {
        let d = try Fixtures.tempDir(self)
        let garbage = d.appendingPathComponent("garbage.m4a")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131) }).write(to: garbage)
        XCTAssertThrowsError(try MediaExtractor().extract(garbage)) { XCTAssertEqual($0 as? ExtractError, .malformed(garbage.path)) }
        let truncated = d.appendingPathComponent("truncated.m4a")
        try Data(try Data(contentsOf: Fixtures.url("clip.m4a")).prefix(512)).write(to: truncated)
        XCTAssertThrowsError(try MediaExtractor().extract(truncated))
        XCTAssertNoThrow(try Extract.extract(garbage))
    }

    /// Speaks a short line with `say`, then rewrites it with iTunes metadata and a QuickTime
    /// chapter track (tx3g text samples associated as the audio's chapter list).
    func testRegenerateClipFixture() async throws {
        guard ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1" else { throw XCTSkip("set FLAMINGO_REGENERATE_FIXTURES=1") }
        let spoken = try Fixtures.tempDir(self).appendingPathComponent("spoken.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", spoken.path, "--file-format=m4af", "--data-format=aac@16000", "--bit-rate=24000",
                         "Arrival. The lagoon. Departure."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let dst = Fixtures.url("clip.m4a")
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: spoken)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let total = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: dst, fileType: .m4a)
        writer.metadata = [
            (AVMetadataIdentifier.commonIdentifierTitle, "Flamingo Field Notes"), (.commonIdentifierArtist, "Ada Marsh"),
            (.commonIdentifierAlbumName, "Lagoon Recordings"), (.commonIdentifierDescription, "Notes spoken at the salt lagoon"),
            (.iTunesMetadataUserComment, "Recorded at dawn"), (.iTunesMetadataLyrics, "Pink birds in shallow water"),
        ].map { id, value in
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            return item
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: try await track.load(.formatDescriptions)[0])
        let textFormat = try Self.tx3gFormat()
        let chapters = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapters.marksOutputTrackAsEnabled = false
        writer.add(audio)
        writer.add(chapters)
        audio.addTrackAssociation(withTrackOf: chapters, type: AVAssetTrack.AssociationType.chapterList.rawValue)

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            while !audio.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            audio.append(sample)
        }
        audio.markAsFinished()
        let starts: [(String, Double)] = [("Arrival", 0), ("The Lagoon", 1), ("Departure", 2)]
        for (i, (title, start)) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].1 : total
            while !chapters.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(chapters.append(try Self.textSample(title, from: start, to: end, format: textFormat)))
        }
        chapters.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    /// An ID3v2.3 tag of Latin-1 text frames (`COMM` bodies are `description\0text`, language
    /// `eng`) over a quarter second of silent 128 kbps MPEG-1 Layer III frames.
    private static func mp3(frames: [(id: String, text: String)]) -> Data {
        var tag = Data()
        for (id, text) in frames {
            let body = Data([0]) + (id == "COMM" ? Data("eng".utf8) : Data()) + Data(text.utf8)
            tag += Data(id.utf8) + withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + Data([0, 0]) + body
        }
        let n = tag.count
        let header = Data("ID3".utf8) + Data([3, 0, 0, UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)])
        let silentFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(count: 413)
        return header + tag + (0..<10).reduce(into: Data()) { d, _ in d += silentFrame }
    }

    /// A 3GPP timed-text sample description: no display flags, default box and style, one font.
    private static func tx3gFormat() throws -> CMFormatDescription {
        let fontTable: [UInt8] = [0, 0, 0, 18] + Array("ftab".utf8) + [0, 1, 0, 1, 5] + Array("Serif".utf8)
        let body: [UInt8] = Array("tx3g".utf8) + [0, 0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 0] + [1, 0xFF] + [0, 0, 0, 0xFF]
            + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 0, 0, 1, 0, 18, 0xFF, 0xFF, 0xFF, 0xFF] + fontTable
        let size = UInt32(body.count + 4)
        let description = withUnsafeBytes(of: size.bigEndian, Array.init) + body
        var format: CMFormatDescription?
        let status = CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
            allocator: nil, bigEndianTextDescriptionData: description, size: description.count, flavor: nil,
            mediaType: kCMMediaType_Text, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw CocoaError(.fileWriteUnknown) }
        return format
    }

    /// One text sample: a big-endian UTF-8 length followed by the text.
    private static func textSample(_ text: String, from start: Double, to end: Double, format: CMFormatDescription) throws -> CMSampleBuffer {
        var bytes = withUnsafeBytes(of: UInt16(text.utf8.count).bigEndian, Array.init) + Array(text.utf8)
        var block: CMBlockBuffer?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: end - start, preferredTimescale: 600),
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr,
              CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
