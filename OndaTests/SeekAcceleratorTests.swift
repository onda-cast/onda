//  SeekAcceleratorTests.swift
import XCTest
@testable import Onda

final class SeekAcceleratorTests: XCTestCase {
    func test_rapidSameDirectionTaps_growAndCapAt4x() {
        var a = SeekAccelerator()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0), 1)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(0.5)), 2)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(1.0)), 4)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(1.5)), 4)
    }

    func test_gapOrDirectionChange_resets() {
        var a = SeekAccelerator()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = a.multiplier(direction: 1, now: t0)
        _ = a.multiplier(direction: 1, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(3.0)), 1)   // gap
        _ = a.multiplier(direction: 1, now: t0.addingTimeInterval(3.2))
        XCTAssertEqual(a.multiplier(direction: -1, now: t0.addingTimeInterval(3.4)), 1)  // flip
    }
}
