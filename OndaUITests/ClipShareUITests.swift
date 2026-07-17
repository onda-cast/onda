//  ClipShareUITests.swift
import XCTest

final class ClipShareUITests: XCTestCase {
    @MainActor
    func test_shareClip_exportsAndPresentsShareSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        // Library tab is the default; open the Clips library.
        let clipsButton = app.buttons["Clips"]
        XCTAssertTrue(clipsButton.waitForExistence(timeout: 10), "Clips entry button missing")
        clipsButton.tap()

        // Seeded clip row appears with its excerpt.
        let excerpt = app.staticTexts["hello world this is a short test"]
        XCTAssertTrue(excerpt.waitForExistence(timeout: 10), "seeded clip not shown")

        // Tap share → exporter runs → system share sheet appears.
        let shareButton = app.buttons["Share clip"].firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        shareButton.tap()

        // UIActivityViewController content: look for the share sheet's collection/other views.
        let shareSheet = app.otherElements["ActivityListView"]
        let appeared = shareSheet.waitForExistence(timeout: 20)
            || app.cells["Copy"].waitForExistence(timeout: 5)
            || app.buttons["Close"].waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "share sheet did not appear after export")
    }

    @MainActor
    func test_exportAllMarkdown_presentsShareSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CLIP"] = "1"
        app.launch()

        let clipsButton = app.buttons["Clips"]
        XCTAssertTrue(clipsButton.waitForExistence(timeout: 10))
        clipsButton.tap()

        let exportAll = app.buttons["Export All"]
        XCTAssertTrue(exportAll.waitForExistence(timeout: 10), "Export All button missing")
        exportAll.tap()

        let appeared = app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
            || app.cells["Copy"].waitForExistence(timeout: 5)
            || app.buttons["Close"].waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "share sheet did not appear for markdown export")
    }
}
