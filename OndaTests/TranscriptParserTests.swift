//  TranscriptParserTests.swift
import XCTest
@testable import Onda

@MainActor
final class TranscriptParserTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: ext)!)
    }

    func test_parseVTT_withSpeaker() throws {
        let cues = TranscriptParser().parse(try fixture("transcript", "vtt"), type: "text/vtt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].endTime, 3, accuracy: 0.001)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertEqual(cues[0].text, "Welcome to the show.")
        XCTAssertEqual(cues[1].startTime, 3, accuracy: 0.001)
    }

    func test_parseSRT() throws {
        let cues = TranscriptParser().parse(try fixture("transcript", "srt"), type: "application/x-subrip")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].endTime, 6.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Today we talk about homepages.")
    }

    func test_parsePC20JSON_withOptionalSpeaker() throws {
        let cues = TranscriptParser().parse(try fixture("transcript_pc20", "json"), type: "application/json")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertNil(cues[1].speaker)
    }

    func test_timestampFormats() {
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02.500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02,500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("01:02.500"), 62.5, accuracy: 0.001)
    }
}
