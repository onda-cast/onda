//  AddByURLProbeUITests.swift
//  Temporary probe for the unified Add by Link sheet: feed detection (local RSS server on
//  localhost:8971) and the article fallback (unreachable port → previewFeed throws).
import XCTest

final class AddByURLProbeUITests: XCTestCase {
    @MainActor
    func test_addByLink_detectsFeed_thenArticleFallback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Library header → Add by Link
        let addButton = app.buttons["Add by Link"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "Add by Link visible on Library")
        addButton.tap()

        let field = app.textFields["add-by-url-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "URL field appears")
        field.tap()
        field.typeText("http://localhost:8971/feed.xml")
        app.buttons["Check link"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Subscribe to Probe Feed Show"].firstMatch
            .waitForExistence(timeout: 10), "RSS URL detected as a podcast feed")
        save(XCUIScreen.main.screenshot(), name: "addurl-feed")

        // Same sheet, non-feed URL → article fallback card.
        field.tap()
        field.press(forDuration: 1.2)
        app.menuItems["Select All"].firstMatch.tap()
        field.typeText("http://localhost:9/story.html")
        app.buttons["Check link"].firstMatch.tap()
        XCTAssertTrue(app.buttons["add-as-article"].firstMatch.waitForExistence(timeout: 15),
                      "non-feed URL offered as an article")
        save(XCUIScreen.main.screenshot(), name: "addurl-article")

        // Discover has the same entry.
        app.swipeDown(velocity: .fast)   // dismiss sheet
        app.buttons["Discover"].tap()
        XCTAssertTrue(app.buttons["Add by Link"].firstMatch.waitForExistence(timeout: 5),
                      "same Add by Link entry on Discover")
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
