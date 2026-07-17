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
}
