//  LibrarySearchSheetProbeUITests.swift
//  Probe: the Search Transcripts sheet opens styled (field visible, themed background).
import XCTest

final class LibrarySearchSheetProbeUITests: XCTestCase {
    @MainActor
    func test_searchSheet_opensWithFieldAndStates() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        let searchButton = app.buttons["Search Transcripts"].firstMatch
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), "library search button present")
        searchButton.tap()

        XCTAssertTrue(app.navigationBars["Search Transcripts"].firstMatch.waitForExistence(timeout: 5),
                      "sheet opens")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field visible")
        XCTAssertTrue(app.staticTexts["Search across every transcript"].firstMatch.exists,
                      "idle empty state visible")
        // Field should sit near the top of the sheet, not floating mid-screen (the unstyled
        // layout centered the whole block vertically).
        let sheetHeight = app.windows.firstMatch.frame.height
        XCTAssertLessThan(field.frame.minY, sheetHeight * 0.35,
                          "search field anchored to the top of the sheet")
        save(XCUIScreen.main.screenshot(), name: "search-sheet")
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
