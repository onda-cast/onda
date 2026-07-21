//  AppearanceProbeUITests.swift
//  Temporary visual probe: captures Discover in light and dark for inspection.
import XCTest

final class AppearanceProbeUITests: XCTestCase {
    @MainActor
    func test_captureDiscoverBothModes() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Discover"].tap()
        sleep(4)   // let trending load
        save(XCUIScreen.main.screenshot(), name: "discover-light")

        app.buttons["Profile"].tap()
        app.switches.firstMatch.tap()   // appearance toggle
        sleep(1)
        app.buttons["Discover"].tap()
        sleep(2)
        save(XCUIScreen.main.screenshot(), name: "discover-dark")
    }

    private func save(_ shot: XCUIScreenshot, name: String) {
        let url = URL(fileURLWithPath: "/tmp/onda-probe-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
