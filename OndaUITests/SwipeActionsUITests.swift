//  SwipeActionsUITests.swift
import XCTest

final class SwipeActionsUITests: XCTestCase {
    @MainActor
    func test_swipeToDelete_removesEpisodeFromList() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        app.staticTexts["UITest Show"].firstMatch.tap()
        XCTAssertTrue(app.buttons["play-episode"].firstMatch.waitForExistence(timeout: 10))
        let cell = app.cells.containing(.button, identifier: "play-episode").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "episode list cell not found")

        cell.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "trailing swipe action missing")
        delete.tap()

        XCTAssertFalse(app.buttons["play-episode"].firstMatch.waitForExistence(timeout: 3),
                       "episode should vanish after delete")
    }
}
