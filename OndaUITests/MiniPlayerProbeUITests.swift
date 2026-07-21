//  MiniPlayerProbeUITests.swift
//  Probe: swipe-to-dismiss on the mini-player, and Discover's scroll-down auto-hide.
import XCTest

final class MiniPlayerProbeUITests: XCTestCase {
    @MainActor
    func test_swipeDismiss_andDiscoverScrollHide() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Start playback from the seeded show's filter list (RECENTLY ADDED → play button).
        app.buttons["RECENTLY ADDED"].firstMatch.tap()
        let play = app.buttons["play-episode"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "seeded episode row visible")
        play.tap()

        let mini = app.buttons["mini-player"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "mini-player appears on play")

        // Swipe it away → gone.
        mini.swipeLeft()
        XCTAssertTrue(waitGone(mini, timeout: 5), "swipe dismisses the mini-player")

        // Play again for the Discover leg.
        play.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))

        // Discover: scroll down hides it, scroll back up reveals it.
        app.buttons["Discover"].tap()
        // Wait for enough content (trending) so the page actually scrolls.
        _ = app.buttons["Follow"].firstMatch.waitForExistence(timeout: 15)   // trending rows in
        drag(app, fromY: 0.7, toY: 0.3)   // controlled drag down — no momentum/bounce
        XCTAssertTrue(waitGone(mini, timeout: 5), "scrolling down Discover hides the mini-player")
        save(XCUIScreen.main.screenshot(), name: "mini-2-hidden")
        drag(app, fromY: 0.3, toY: 0.75)  // sustained scroll up
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "scrolling back up reveals it")

        // Tab switch also restores.
        drag(app, fromY: 0.7, toY: 0.3)
        _ = waitGone(mini, timeout: 5)
        app.buttons["Library"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "switching tabs restores the bar")

        // Discover search: focusing the search field hides the bar; unfocusing restores it.
        app.buttons["Discover"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        XCTAssertTrue(waitGone(mini, timeout: 5), "focusing Discover search hides the mini-player")
        XCTAssertFalse(app.buttons["Library"].firstMatch.isHittable,
                       "tab bar also hides while searching")
        // Tap a neutral spot near the header — the tap-anywhere gesture clears search focus.
        // (Can't tap a tab label: the tab bar itself is hidden during search now.)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "leaving search restores the mini-player")
        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 5),
                      "tab bar returns when search ends")
    }

    @MainActor
    private func drag(_ app: XCUIApplication, fromY: CGFloat, toY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    @MainActor
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }
}
