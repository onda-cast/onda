//  AddByURLProbeUITests.swift
//  Probe for the unified Add by Link sheet against a local server (scripts: serve a directory
//  containing feed.xml, story.html, and bad.xml on port 8971). Skips when the server isn't up so
//  combined suite runs stay green without it.
import XCTest

final class AddByURLProbeUITests: XCTestCase {
    private let base = "http://localhost:8971"

    @MainActor
    func test_addByLink_feed_article_brokenFeed() throws {
        try XCTSkipUnless(probeServerIsUp(), "probe server not running on :8971 — see file header")

        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Library header → Add by Link
        let addButton = app.buttons["Add by Link"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "Add by Link visible on Library")
        addButton.tap()

        let field = app.textFields["add-by-url-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "URL field appears")

        // 1. Real RSS → feed card.
        enter("\(base)/feed.xml", into: field, app: app)
        XCTAssertTrue(app.buttons["Subscribe to Probe Feed Show"].firstMatch
            .waitForExistence(timeout: 10), "RSS URL detected as a podcast feed")
        save(XCUIScreen.main.screenshot(), name: "addurl-feed")

        // 2. HTML page → article card.
        enter("\(base)/story.html", into: field, app: app)
        XCTAssertTrue(app.buttons["add-as-article"].firstMatch.waitForExistence(timeout: 10),
                      "HTML URL offered as an article")
        save(XCUIScreen.main.screenshot(), name: "addurl-article")

        // 3. XML that isn't a valid feed → broken-feed error, NOT the article card.
        enter("\(base)/bad.xml", into: field, app: app)
        let brokenText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "looks like a podcast feed")
        ).firstMatch
        XCTAssertTrue(brokenText.waitForExistence(timeout: 10),
                      "unparseable XML reported as a broken feed")
        XCTAssertFalse(app.buttons["add-as-article"].firstMatch.exists,
                       "broken feed must not be offered as an article")
        save(XCUIScreen.main.screenshot(), name: "addurl-broken")

        // Discover has the same entry.
        app.swipeDown(velocity: .fast)   // dismiss sheet
        app.buttons["Discover"].tap()
        XCTAssertTrue(app.buttons["Add by Link"].firstMatch.waitForExistence(timeout: 5),
                      "same Add by Link entry on Discover")
    }

    @MainActor
    private func enter(_ url: String, into field: XCUIElement, app: XCUIApplication) {
        field.tap()
        // Replace any existing text wholesale.
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
        field.typeText(url)
        app.buttons["Check link"].firstMatch.tap()
    }

    private func probeServerIsUp() -> Bool {
        let exp = expectation(description: "probe server reachable")
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: URL(string: "\(base)/feed.xml")!) { data, _, error in
            ok = error == nil && data != nil
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)
        return ok
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
