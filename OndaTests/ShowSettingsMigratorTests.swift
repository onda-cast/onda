//  ShowSettingsMigratorTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ShowSettingsMigratorTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_normalize_nilsOutOldHardcodedDefaults() {
        let s = ShowSettings()
        s.speed = 1.0; s.voiceBoost = 0; s.skipSilence = false
        s.adSkipMode = "off"; s.autoDownload = false
        ShowSettingsMigrator.normalize(s)
        XCTAssertNil(s.speed); XCTAssertNil(s.voiceBoost); XCTAssertNil(s.skipSilence)
        XCTAssertNil(s.adSkipMode); XCTAssertNil(s.autoDownload)
    }

    func test_normalize_keepsCustomizedValuesAsOverrides() {
        let s = ShowSettings()
        s.speed = 1.5; s.voiceBoost = 2; s.skipSilence = true
        s.adSkipMode = "auto"; s.autoDownload = true
        ShowSettingsMigrator.normalize(s)
        XCTAssertEqual(s.speed, 1.5); XCTAssertEqual(s.voiceBoost, 2)
        XCTAssertEqual(s.skipSilence, true); XCTAssertEqual(s.adSkipMode, "auto")
        XCTAssertEqual(s.autoDownload, true)
    }

    func test_normalizeAll_runsOnceAndSetsFlag() throws {
        let ctx = try makeContext()
        let suite = "MigratorTests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        let s = ShowSettings(); s.speed = 1.0
        ctx.insert(s); try ctx.save()
        ShowSettingsMigrator.normalizeAll(in: ctx, defaults: d)
        XCTAssertNil(s.speed)
        // Second run must be a no-op even if a default-valued row reappears.
        let s2 = ShowSettings(); s2.speed = 1.0
        ctx.insert(s2); try ctx.save()
        ShowSettingsMigrator.normalizeAll(in: ctx, defaults: d)
        XCTAssertEqual(s2.speed, 1.0)
    }
}
