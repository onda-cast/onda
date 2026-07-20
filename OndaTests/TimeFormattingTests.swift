//  TimeFormattingTests.swift
import XCTest
@testable import Onda

final class TimeFormattingTests: XCTestCase {
    func test_underAnHour_formatsMinutesSeconds() {
        XCTAssertEqual(TimeFormatting.timeStr(65), "1:05")
        XCTAssertEqual(TimeFormatting.timeStr(0), "0:00")
        XCTAssertEqual(TimeFormatting.timeStr(3599), "59:59")
    }

    func test_atOrPastAnHour_formatsHoursMinutesSeconds() {
        // Regression: LibrarySearchView used to always show M:SS, so a hit at 65 minutes read
        // "65:23" there and "1:05:23" in TranscriptView — same timestamp, two formats.
        XCTAssertEqual(TimeFormatting.timeStr(3600), "1:00:00")
        XCTAssertEqual(TimeFormatting.timeStr(65 * 60 + 23), "1:05:23")
    }

    func test_negative_clampsToZero() {
        XCTAssertEqual(TimeFormatting.timeStr(-5), "0:00")
    }
}
