//  SkipSilenceProbeUITests.swift
//  Plays the seeded local episode (with 1.5-2s silences) so tap diagnostics stream to the log.
import XCTest

final class SkipSilenceProbeUITests: XCTestCase {
    @MainActor
    func test_playSeededEpisode_forTapDiagnostics() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        let playButton = app.buttons["play-episode"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10), "episode play button not found")
        playButton.tap()
        sleep(14)   // fixture is ~10s + margin; tap logs accumulate meanwhile
    }
}
