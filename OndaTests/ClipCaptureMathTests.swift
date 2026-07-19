//  ClipCaptureMathTests.swift
import XCTest
@testable import Onda

@MainActor
final class ClipCaptureMathTests: XCTestCase {
    func test_clipStart_looksBack5s_flooredAtZero() {
        XCTAssertEqual(NowPlayingView.clipStartValue(position: 100), 95)
        XCTAssertEqual(NowPlayingView.clipStartValue(position: 3), 0, "never before the episode start")
    }

    func test_clipEnd_isTapPosition_butAtLeastMinLengthAfterStart() {
        XCTAssertEqual(NowPlayingView.clipEnd(start: 95, position: 130), 130)
        // Tapping End immediately after Start: enforce the 1s minimum length.
        XCTAssertEqual(NowPlayingView.clipEnd(start: 95, position: 95.2),
                       95 + ClipReviewSheet.minLength)
    }
}
