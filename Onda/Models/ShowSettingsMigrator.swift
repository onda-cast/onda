//  ShowSettingsMigrator.swift
//  One-time normalization after playback fields became optional overrides: a stored value equal
//  to the old hardcoded default means "the user never touched this", so it becomes nil (inherit)
//  and starts tracking the global default. Any other value is a real customization and stays.
import Foundation
import SwiftData

enum ShowSettingsMigrator {
    static let migrationFlagKey = "showSettingsOverrideMigrationDone"

    static func normalize(_ s: ShowSettings) {
        if s.speed == 1.0 { s.speed = nil }
        if s.voiceBoost == 0 { s.voiceBoost = nil }
        if s.skipSilence == false { s.skipSilence = nil }
        if s.adSkipMode == "off" { s.adSkipMode = nil }
        if s.autoDownload == false { s.autoDownload = nil }
    }

    @MainActor
    static func normalizeAll(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        let all = (try? context.fetch(FetchDescriptor<ShowSettings>())) ?? []
        for s in all { normalize(s) }
        try? context.save()
        defaults.set(true, forKey: migrationFlagKey)
    }
}
