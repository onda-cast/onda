//  AdWindowTests.swift
import XCTest
@testable import Onda

@MainActor
final class AdWindowTests: XCTestCase {
    private func window() -> AdWindow {
        AdWindow(chapters: [(0, false), (600, true), (780, false)], duration: 2292)
    }

    func test_isAd_insideAdChapter() {
        let w = window()
        XCTAssertFalse(w.isAd(at: 100))
        XCTAssertTrue(w.isAd(at: 650))
        XCTAssertFalse(w.isAd(at: 900))
    }

    func test_adEnd_returnsNextNonAdStart() {
        let w = window()
        XCTAssertEqual(w.adEnd(at: 650), 780)
        XCTAssertNil(w.adEnd(at: 100))
    }

    func test_trailingAd_endsAtDuration() {
        let w = AdWindow(chapters: [(0, false), (2000, true)], duration: 2292)
        XCTAssertEqual(w.adEnd(at: 2100), 2292)
    }
}
