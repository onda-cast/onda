//  TimecodeParseTests.swift
import XCTest
@testable import Onda

final class TimecodeParseTests: XCTestCase {
    func test_plainSeconds() {
        XCTAssertEqual(NowPlayingView.parseTimecode("90"), 90)
        XCTAssertEqual(NowPlayingView.parseTimecode("0"), 0)
        XCTAssertEqual(NowPlayingView.parseTimecode(" 437 "), 437, "whitespace trimmed")
    }

    func test_minutesSeconds() {
        XCTAssertEqual(NowPlayingView.parseTimecode("12:34"), 12 * 60 + 34)
        XCTAssertEqual(NowPlayingView.parseTimecode("0:05"), 5)
        XCTAssertEqual(NowPlayingView.parseTimecode("90:00"), 90 * 60, "leading field may exceed 59")
    }

    func test_hoursMinutesSeconds() {
        XCTAssertEqual(NowPlayingView.parseTimecode("1:02:30"), 3750)
        XCTAssertEqual(NowPlayingView.parseTimecode("0:00:00"), 0)
    }

    func test_rejectsMalformed() {
        XCTAssertNil(NowPlayingView.parseTimecode(""))
        XCTAssertNil(NowPlayingView.parseTimecode("abc"))
        XCTAssertNil(NowPlayingView.parseTimecode("1:2:3:4"), "too many fields")
        XCTAssertNil(NowPlayingView.parseTimecode("12:"), "empty field")
        XCTAssertNil(NowPlayingView.parseTimecode(":30"), "empty field")
        XCTAssertNil(NowPlayingView.parseTimecode("1:60"), "seconds must be 0–59")
        XCTAssertNil(NowPlayingView.parseTimecode("1:75:00"), "minutes must be 0–59")
        XCTAssertNil(NowPlayingView.parseTimecode("-5"))
        XCTAssertNil(NowPlayingView.parseTimecode("1:-5"))
        XCTAssertNil(NowPlayingView.parseTimecode("1.5:00"), "no fractional fields")
    }
}
