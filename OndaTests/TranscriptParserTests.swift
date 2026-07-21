//  TranscriptParserTests.swift
import XCTest
@testable import Onda

@MainActor
final class TranscriptParserTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: ext)!)
    }

    func test_parseVTT_withSpeaker() throws {
        let cues = try TranscriptParser().parse(fixture("transcript", "vtt"), type: "text/vtt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].endTime, 3, accuracy: 0.001)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertEqual(cues[0].text, "Welcome to the show.")
        XCTAssertEqual(cues[1].startTime, 3, accuracy: 0.001)
    }

    func test_parseSRT() throws {
        let cues = try TranscriptParser().parse(fixture("transcript", "srt"), type: "application/x-subrip")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].endTime, 6.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Today we talk about homepages.")
    }

    func test_parsePC20JSON_withOptionalSpeaker() throws {
        let cues = try TranscriptParser().parse(fixture("transcript_pc20", "json"), type: "application/json")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertNil(cues[1].speaker)
    }

    func test_timestampFormats() {
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02.500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02,500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("01:02.500"), 62.5, accuracy: 0.001)
    }

    // Regression: a cue-timing line with no end timestamp, or with cue settings glued directly
    // onto it with no separating space, used to silently produce a zero-length/garbled cue
    // instead of being skipped.
    func test_malformedTiming_missingEndTimestamp_cueSkipped() {
        let vtt = """
        WEBVTT

        00:00:01.000 -->
        Orphaned line with no end time.

        00:00:05.000 --> 00:00:07.000
        A well-formed cue that must still parse.
        """
        let cues = TranscriptParser().parse(Data(vtt.utf8), type: "text/vtt")
        XCTAssertEqual(cues.count, 1, "the malformed cue is skipped, not zero-timed")
        XCTAssertEqual(cues[0].text, "A well-formed cue that must still parse.")
    }

    func test_malformedTiming_settingsGluedWithNoSpace_cueSkipped() {
        let vtt = """
        WEBVTT

        00:00:10.000 -->00:00:12.000align:start
        Glued cue settings, no space before the end timestamp.

        00:00:15.000 --> 00:00:16.000
        Next cue is unaffected.
        """
        let cues = TranscriptParser().parse(Data(vtt.utf8), type: "text/vtt")
        XCTAssertEqual(cues.count, 1, "the glued/garbled timing line is skipped")
        XCTAssertEqual(cues[0].text, "Next cue is unaffected.")
    }

    func test_endBeforeStart_cueSkipped() {
        let vtt = """
        WEBVTT

        00:00:20.000 --> 00:00:10.000
        End before start — clearly garbled.

        00:00:25.000 --> 00:00:26.000
        A valid cue after it.
        """
        let cues = TranscriptParser().parse(Data(vtt.utf8), type: "text/vtt")
        XCTAssertEqual(cues.count, 1, "end < start is rejected rather than rendered")
        XCTAssertEqual(cues[0].text, "A valid cue after it.")
    }

    // Regression: the JSON path lacked the end >= start guard the VTT/SRT path enforces, so a
    // malformed Podcasting 2.0 JSON segment (end < start) was persisted as a negative-length cue.
    func test_json_endBeforeStart_cueSkipped() {
        let json = """
        { "segments": [
          { "startTime": 30, "endTime": 25, "body": "Garbled backwards segment." },
          { "startTime": 40, "endTime": 42, "body": "A valid segment after it." }
        ] }
        """
        let cues = TranscriptParser().parse(Data(json.utf8), type: "application/json")
        XCTAssertEqual(cues.count, 1, "end < start is rejected in the JSON path too")
        XCTAssertEqual(cues[0].text, "A valid segment after it.")
    }
}
