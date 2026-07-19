//  ClipTextSnapshotTests.swift
import XCTest
@testable import Onda

@MainActor
final class ClipTextSnapshotTests: XCTestCase {
    private let cues: [CueSpan] = [
        CueSpan(start: 0, end: 10, text: "alpha"), CueSpan(start: 10, end: 20, text: "beta"),
        CueSpan(start: 20, end: 30, text: "gamma"), CueSpan(start: 30, end: 40, text: "delta")
    ]

    func test_rangeSnapsOutwardToCueBoundaries() {
        let r = ClipTextSnapshot.snap(cues: cues, requestedStart: 12, requestedEnd: 24)
        XCTAssertEqual(r.start, 10); XCTAssertEqual(r.end, 30)
        XCTAssertEqual(r.text, "beta gamma")
    }

    func test_noOverlap_returnsRequestedRangeEmptyText() {
        let r = ClipTextSnapshot.snap(cues: [], requestedStart: 5, requestedEnd: 15)
        XCTAssertEqual(r.start, 5); XCTAssertEqual(r.end, 15)
        XCTAssertEqual(r.text, "")
    }

    func test_exactCueRange() {
        let r = ClipTextSnapshot.snap(cues: cues, requestedStart: 10, requestedEnd: 20)
        XCTAssertEqual(r.text, "beta")
    }

    // MARK: - text(cues:start:end:) — exact-times variant (no boundary expansion)

    func test_text_joinsOverlappingCues() {
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 12, end: 24), "beta gamma")
    }

    func test_text_noOverlap_returnsEmpty() {
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 45, end: 50), "")
        XCTAssertEqual(ClipTextSnapshot.text(cues: [], start: 5, end: 15), "")
    }

    func test_text_edgeTouchingCuesExcluded() {
        // alpha ends exactly at start (10) and delta starts exactly at end (30):
        // half-open [start, end) excludes both.
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 10, end: 30), "beta gamma")
    }
}
