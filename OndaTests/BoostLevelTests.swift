//  BoostLevelTests.swift
import XCTest
@testable import Onda

@MainActor
final class BoostLevelTests: XCTestCase {
    func test_gainPerLevel() {
        XCTAssertEqual(BoostLevel.off.gain, 1.0)
        XCTAssertEqual(BoostLevel.medium.gain, 1.6, accuracy: 0.001)
        XCTAssertEqual(BoostLevel.high.gain, 2.4, accuracy: 0.001)
    }

    func test_clampingOutOfRange() {
        XCTAssertEqual(BoostLevel(clamping: -1), .off)
        XCTAssertEqual(BoostLevel(clamping: 5), .high)
        XCTAssertEqual(BoostLevel(clamping: 1), .medium)
    }
}
