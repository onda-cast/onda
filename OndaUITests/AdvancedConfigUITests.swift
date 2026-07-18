//  AdvancedConfigUITests.swift
//  Smoke coverage for the advanced-config surfaces: the Profile "Playback" defaults section,
//  the download-policy rows, the per-show Default/Custom override pickers, and the player's
//  configurable skip buttons.
import XCTest

final class AdvancedConfigUITests: XCTestCase {
    @MainActor
    func test_profile_showsPlaybackDefaults_andDownloadPolicy() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Smart Resume"].waitForExistence(timeout: 5),
                      "Playback section missing from Profile")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Autoplay Next"].exists
                      || app.staticTexts["Autoplay Next"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Wi-Fi only downloads"].waitForExistence(timeout: 3),
                      "Wi-Fi-only toggle missing")
        XCTAssertTrue(app.staticTexts["Delete played episodes"].waitForExistence(timeout: 3),
                      "delete-played presets missing")
    }

    @MainActor
    func test_showSettingsSheet_showsOverridePickers() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        let gear = app.buttons["show-settings-button"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "settings gear not found")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Voice Boost"].waitForExistence(timeout: 5),
                      "show settings sheet did not open")
        // Override pickers expose a "Default" segment per playback effect group.
        XCTAssertTrue(app.buttons["Default"].firstMatch.exists,
                      "Default/Custom override segments missing")
    }

    @MainActor
    func test_player_skipButtons_reflectConfiguredIntervals() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        let play = app.buttons["play-episode"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'UITest Episode'")).firstMatch.tap()
        // Defaults: forward 30 / back 15 — the accessibility labels carry the configured value.
        XCTAssertTrue(app.buttons["Skip forward 30 seconds"].waitForExistence(timeout: 5),
                      "forward skip button should reflect the configured 30s interval")
        XCTAssertTrue(app.buttons["Skip back 15 seconds"].exists,
                      "back skip button should reflect the configured 15s interval")
    }
}
