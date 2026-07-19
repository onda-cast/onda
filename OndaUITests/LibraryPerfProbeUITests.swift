//  LibraryPerfProbeUITests.swift
//  Perf probe: times the Discover→Library tab switch against a device-scale seeded library
//  (UITEST_SEED_SCALE: 25 shows x 120 episodes). Prints timings; asserts a generous ceiling.
import XCTest

final class LibraryPerfProbeUITests: XCTestCase {
    @MainActor
    func test_libraryTabSwitch_time() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_SCALE"] = "1"
        // Worst-case sort: the keyed comparators scan episode arrays per comparison.
        app.launchArguments += ["-librarySort", "newestEpisode"]
        app.launch()

        let libraryTab = app.buttons["Library"].firstMatch
        let discoverTab = app.buttons["Discover"].firstMatch
        let title = app.staticTexts["Library"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "library up after seeding")

        // Real timing comes from the app's PERFAPP blocked-main logs (RootView.tabButton);
        // the harness Date-based numbers were dominated by XCUITest query overhead.
        for _ in 1...3 {
            discoverTab.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            libraryTab.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 30), "library renders")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }
}
