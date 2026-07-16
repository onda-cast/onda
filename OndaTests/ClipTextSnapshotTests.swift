//  ClipTextSnapshotTests.swift
import XCTest
@testable import Onda

@MainActor
final class ClipTextSnapshotTests: XCTestCase {
    private let cues: [(start: TimeInterval, end: TimeInterval, text: String)] = [
        (0, 10, "alpha"), (10, 20, "beta"), (20, 30, "gamma"), (30, 40, "delta"),
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
