//  BooksButtonProbeUITests.swift
//  Probe: the player header's books button opens the Books Mentioned sheet.
//  The funnel itself needs network + a real feed, so this stops at the sheet's empty state.
import XCTest

final class BooksButtonProbeUITests: XCTestCase {
    @MainActor
    func test_booksButton_opensBooksSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Start playback from the seeded show's filter list, then open the full player.
        app.buttons["RECENTLY ADDED"].firstMatch.tap()
        let play = app.buttons["play-episode"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "seeded episode row visible")
        play.tap()

        let mini = app.buttons["mini-player"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "mini-player appears on play")
        mini.tap()

        let booksButton = app.buttons["books-button"].firstMatch
        XCTAssertTrue(booksButton.waitForExistence(timeout: 5), "books button in the player header")
        booksButton.tap()

        XCTAssertTrue(app.staticTexts["Books Mentioned"].firstMatch.waitForExistence(timeout: 5),
                      "Books Mentioned sheet opens")
        // The CTA's element label is its accessibilityLabel, not the visible "Find Books" text.
        XCTAssertTrue(app.buttons["Find books mentioned in this episode"].firstMatch
            .waitForExistence(timeout: 5),
            "Find Books CTA visible in the empty state")
    }
}
