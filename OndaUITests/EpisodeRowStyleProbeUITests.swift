//  EpisodeRowStyleProbeUITests.swift
//  Visual probe: episode row icons + open swipe action for design review.
import XCTest

final class EpisodeRowStyleProbeUITests: XCTestCase {
    @MainActor
    func test_captureRowAndSwipeStyles() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        let cell = app.cells.containing(.button, identifier: "play-episode").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/onda-row-style.png"))

        cell.swipeLeft()
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/onda-swipe-style.png"))
    }
}
