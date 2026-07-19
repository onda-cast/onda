//  ShowSettingsSpeedSeedTests.swift
import XCTest
@testable import Onda

@MainActor
final class ShowSettingsSpeedSeedTests: XCTestCase {
    func test_seed_isNextStepAboveGlobal() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.0), 1.25,
                       "a fresh Custom must be visibly different from Default")
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.5), 1.75)
    }

    func test_seed_wrapsAtTopOfRange() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 2.0), 0.75)
    }

    func test_seed_offGridGlobal_snapsToNextHigherStep() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.1), 1.25)
    }
}
