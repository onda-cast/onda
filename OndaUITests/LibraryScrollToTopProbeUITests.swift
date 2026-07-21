//  LibraryScrollToTopProbeUITests.swift
//  Probe: tapping the library view-options (layout menu) button scrolls back to the top.
import XCTest

final class LibraryScrollToTopProbeUITests: XCTestCase {
    @MainActor
    func test_layoutMenuButton_scrollsToTop() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_SCALE"] = "1"   // 25 shows — enough to scroll
        app.launch()

        // The tab bar's own "Library" label is always on screen — match the page header by
        // its identifier, not by text, or isHittable never goes false while scrolled.
        let title = app.staticTexts["library-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "library up after seeding")
        XCTAssertTrue(title.isHittable, "starts scrolled to top")

        // Scroll down until the header is off-screen.
        for _ in 0 ..< 6 { app.swipeUp() }
        XCTAssertFalse(title.isHittable, "scrolled away from the top")

        // Tap the layout/sort menu button — it should also jump the list back to the top.
        let layoutButton = app.buttons["Library view options"].firstMatch
        XCTAssertTrue(layoutButton.waitForExistence(timeout: 5))
        layoutButton.tap()
        // Dismiss the popup menu itself — it opens right where the header now is, so check
        // the scroll landed by tapping elsewhere first, then re-verifying the header shows.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        XCTAssertTrue(title.waitForExistence(timeout: 5), "back at the top after tapping the menu button")
        XCTAssertTrue(title.isHittable, "header visible again")
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists { tap() }
    }
}
