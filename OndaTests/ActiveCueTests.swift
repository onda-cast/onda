//  ActiveCueTests.swift
import XCTest
@testable import Onda

@MainActor
final class ActiveCueTests: XCTestCase {
    private let cues: [(start: TimeInterval, end: TimeInterval)] = [(0, 3), (3, 6.5), (10, 12)]
    func test_insideCue() {
        XCTAssertEqual(ActiveCue.index(at: 4, cues: cues), 1)
    }

    func test_beforeFirst() {
        XCTAssertNil(ActiveCue.index(at: -1, cues: cues))
    }

    func test_betweenCues_returnsMostRecentPast() {
        XCTAssertEqual(ActiveCue.index(at: 8, cues: cues), 1)
    }

    func test_afterLast() {
        XCTAssertEqual(ActiveCue.index(at: 100, cues: cues), 2)
    }
}
