//  EpisodeSearchUITests.swift
import XCTest

final class EpisodeSearchUITests: XCTestCase {
    @MainActor
    func test_search_filtersEpisodesByMetadata() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Open the seeded show's episode list.
        app.staticTexts["UITest Show"].firstMatch.tap()
        XCTAssertTrue(app.buttons["play-episode"].firstMatch.waitForExistence(timeout: 10),
                      "episode row should be visible before searching")

        let field = app.textFields["episode-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search bar missing from episode list")

        // A term that matches nothing hides the episode and shows the empty state.
        field.tap()
        field.typeText("germany")
        let emptyState = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "No episodes match")
        ).firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5),
                      "non-matching query should show the empty state")
        XCTAssertFalse(app.buttons["play-episode"].firstMatch.exists,
                       "non-matching query should hide the episode row")

        // A term that matches the episode title brings the row back.
        field.typeText(XCUIKeyboardKey.delete.rawValue.repeated(7))  // clear "germany"
        field.typeText("uitest")
        XCTAssertTrue(app.buttons["play-episode"].firstMatch.waitForExistence(timeout: 5),
                      "title match should show the episode row again")
        XCTAssertFalse(emptyState.exists, "matching query should not show the empty state")
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
