//  AppSettingsTests.swift
import XCTest
@testable import Onda

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_playbackDefaults_haveExpectedInitialValues() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(s.defaultSpeed, 1.0)
        XCTAssertEqual(s.defaultVoiceBoost, 0)
        XCTAssertFalse(s.defaultSkipSilence)
        XCTAssertEqual(s.defaultAdSkipMode, "off")
        XCTAssertFalse(s.defaultAutoDownload)
        XCTAssertEqual(s.seekForwardSec, 30)
        XCTAssertEqual(s.seekBackSec, 15)
        XCTAssertTrue(s.smartResumeEnabled)
        XCTAssertTrue(s.autoplayNext)
        XCTAssertTrue(s.seekAccelerationEnabled)
        XCTAssertTrue(s.wifiOnlyDownloads)
    }

    func test_playbackDefaults_persistAcrossInstances() {
        let d = makeDefaults()
        let s = AppSettings(defaults: d)
        s.defaultSpeed = 1.5
        s.defaultVoiceBoost = 2
        s.seekForwardSec = 45
        s.autoplayNext = false
        s.wifiOnlyDownloads = false
        let reloaded = AppSettings(defaults: d)
        XCTAssertEqual(reloaded.defaultSpeed, 1.5)
        XCTAssertEqual(reloaded.defaultVoiceBoost, 2)
        XCTAssertEqual(reloaded.seekForwardSec, 45)
        XCTAssertFalse(reloaded.autoplayNext)
        XCTAssertFalse(reloaded.wifiOnlyDownloads)
    }
}
