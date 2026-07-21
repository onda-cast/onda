//  LibraryFreezeProbeUITests.swift
//  Temporary probe: reproduce the reported "Library page freezes / not interactive".
import XCTest

final class LibraryFreezeProbeUITests: XCTestCase {
    @MainActor
    func test_libraryStaysInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Library is the default tab; the seeded show should be present and hittable.
        let show = app.staticTexts["UITest Show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10), "seeded show visible")
        save(XCUIScreen.main.screenshot(), name: "lib-1-initial")

        // Tap a filter chip → filtered episode list with PLAY ALL.
        let chip = app.buttons["RECENTLY ADDED"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "chips row visible")
        chip.tap()
        let playAll = app.buttons["Play all 1 episodes"].firstMatch
        XCTAssertTrue(playAll.waitForExistence(timeout: 5), "filtered list with Play All appears")
        save(XCUIScreen.main.screenshot(), name: "lib-2-filtered")

        // Toggle the chip off → back to the grid, still interactive.
        chip.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5), "grid restored after clearing filter")

        // Tab bar still responds.
        app.buttons["Discover"].tap()
        XCTAssertTrue(app.staticTexts["DISCOVER"].firstMatch.waitForExistence(timeout: 5)
            || app.buttons["Shuffle new podcasts"].firstMatch.waitForExistence(timeout: 5),
            "Discover reachable")
        app.buttons["Library"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5), "back on Library, interactive")
        save(XCUIScreen.main.screenshot(), name: "lib-3-final")
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
