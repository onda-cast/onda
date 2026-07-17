//  ThemeTests.swift
import XCTest
import SwiftUI
@testable import Onda

@MainActor
final class ThemeTests: XCTestCase {
    func test_toggle_flipsAppearance() {
        let theme = AppTheme(appearance: .light, persist: false)
        XCTAssertEqual(theme.appearance, .light)
        theme.toggle()
        XCTAssertEqual(theme.appearance, .dark)
        theme.toggle()
        XCTAssertEqual(theme.appearance, .light)
    }

    func test_colorScheme_matchesAppearance() {
        XCTAssertEqual(AppTheme(appearance: .dark, persist: false).colorScheme, .dark)
        XCTAssertEqual(AppTheme(appearance: .light, persist: false).colorScheme, .light)
        XCTAssertNil(AppTheme(appearance: .system, persist: false).colorScheme,
                     "system follows the device — no forced scheme")
    }

    func test_systemMode_resolvesToDeviceScheme() {
        let theme = AppTheme(appearance: .system, persist: false, systemIsDark: true)
        XCTAssertEqual(theme.resolvedAppearance, .dark)
        theme.systemIsDark = false
        XCTAssertEqual(theme.resolvedAppearance, .light, "colours track the device scheme in system mode")
    }

    func test_explicitMode_ignoresDeviceScheme() {
        let theme = AppTheme(appearance: .light, persist: false, systemIsDark: true)
        XCTAssertEqual(theme.resolvedAppearance, .light, "explicit light stays light even on a dark device")
    }

    func test_tokens_differBetweenAppearances() {
        let lightBg = OndaColors.token(.bg, for: .light)
        let darkBg = OndaColors.token(.bg, for: .dark)
        XCTAssertNotEqual(lightBg.description, darkBg.description)
    }
}
