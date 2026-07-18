//  ResolvedPlaybackSettingsTests.swift
import XCTest
@testable import Onda

@MainActor
final class ResolvedPlaybackSettingsTests: XCTestCase {
    private func makeApp() -> AppSettings {
        let suite = "ResolvedTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }

    func test_nilShow_inheritsEveryGlobal() {
        let app = makeApp()
        app.defaultSpeed = 1.5; app.defaultVoiceBoost = 1; app.defaultSkipSilence = true
        app.defaultAdSkipMode = "manual"; app.defaultAutoDownload = true
        let r = ResolvedPlaybackSettings(show: nil, app: app)
        XCTAssertEqual(r.speed, 1.5); XCTAssertEqual(r.voiceBoost, 1)
        XCTAssertTrue(r.skipSilence); XCTAssertEqual(r.adSkipMode, "manual")
        XCTAssertTrue(r.autoDownload)
    }

    func test_showOverride_winsPerField() {
        let app = makeApp()
        app.defaultSpeed = 1.5
        let s = ShowSettings()
        s.speed = 2.0           // overridden
        s.voiceBoost = nil      // inherited (0)
        let r = ResolvedPlaybackSettings(show: s, app: app)
        XCTAssertEqual(r.speed, 2.0)
        XCTAssertEqual(r.voiceBoost, 0)
    }
}
