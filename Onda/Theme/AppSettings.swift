//  AppSettings.swift
import Foundation

@MainActor
@Observable
final class AppSettings {
    private static let keepTranscriptsKey = "keepTranscriptsOnDelete"
    private static let maxDownloadsKey = "defaultMaxDownloadsKept"
    private static let autoDeleteDaysKey = "defaultAutoDeleteListenedAfterDays"
    private static let autoTranscribeKey = "defaultAutoTranscribeOnDownload"
    private static let defaultSpeedKey = "defaultSpeed"
    private static let defaultBoostKey = "defaultVoiceBoost"
    private static let defaultSkipSilenceKey = "defaultSkipSilence"
    private static let defaultAdSkipKey = "defaultAdSkipMode"
    private static let defaultAutoDownloadKey = "defaultAutoDownload"
    private static let seekForwardKey = "seekForwardSec"
    private static let seekBackKey = "seekBackSec"
    private static let smartResumeKey = "smartResumeEnabled"
    private static let autoplayNextKey = "autoplayNext"
    private static let seekAccelKey = "seekAccelerationEnabled"
    private static let wifiOnlyKey = "wifiOnlyDownloads"

    private let defaults: UserDefaults

    // Default true: retaining searchable transcripts of deleted episodes is the point of Onda.
    var keepTranscriptsOnDelete: Bool {
        didSet { defaults.set(keepTranscriptsOnDelete, forKey: Self.keepTranscriptsKey) }
    }

    /// Per-show cap on TOTAL downloaded episodes. 0 = no limit (the default — no surprise
    /// deletions). The cap only ever evicts played episodes.
    var defaultMaxDownloadsKept: Int {
        didSet { defaults.set(defaultMaxDownloadsKept, forKey: Self.maxDownloadsKey) }
    }

    /// Auto-delete listened episodes after N days. -1 = off (default), 0 = immediately.
    var defaultAutoDeleteListenedAfterDays: Int {
        didSet { defaults.set(defaultAutoDeleteListenedAfterDays, forKey: Self.autoDeleteDaysKey) }
    }

    /// Auto-start on-device transcription when a download finishes (episodes without a
    /// published transcript, engine available, Speech authorization already granted).
    var defaultAutoTranscribeOnDownload: Bool {
        didSet { defaults.set(defaultAutoTranscribeOnDownload, forKey: Self.autoTranscribeKey) }
    }

    // MARK: Global playback defaults — a show inherits these unless it has an override.

    var defaultSpeed: Double {
        didSet { defaults.set(defaultSpeed, forKey: Self.defaultSpeedKey) }
    }

    var defaultVoiceBoost: Int {
        didSet { defaults.set(defaultVoiceBoost, forKey: Self.defaultBoostKey) }
    }

    var defaultSkipSilence: Bool {
        didSet { defaults.set(defaultSkipSilence, forKey: Self.defaultSkipSilenceKey) }
    }

    var defaultAdSkipMode: String {
        didSet { defaults.set(defaultAdSkipMode, forKey: Self.defaultAdSkipKey) }
    }

    var defaultAutoDownload: Bool {
        didSet { defaults.set(defaultAutoDownload, forKey: Self.defaultAutoDownloadKey) }
    }

    // MARK: Nitpicky details

    var seekForwardSec: Int {
        didSet { defaults.set(seekForwardSec, forKey: Self.seekForwardKey) }
    }

    var seekBackSec: Int {
        didSet { defaults.set(seekBackSec, forKey: Self.seekBackKey) }
    }

    var smartResumeEnabled: Bool {
        didSet { defaults.set(smartResumeEnabled, forKey: Self.smartResumeKey) }
    }

    var autoplayNext: Bool {
        didSet { defaults.set(autoplayNext, forKey: Self.autoplayNextKey) }
    }

    var seekAccelerationEnabled: Bool {
        didSet { defaults.set(seekAccelerationEnabled, forKey: Self.seekAccelKey) }
    }

    // MARK: Download policy

    var wifiOnlyDownloads: Bool {
        didSet { defaults.set(wifiOnlyDownloads, forKey: Self.wifiOnlyKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepTranscriptsOnDelete = defaults.object(forKey: Self.keepTranscriptsKey)
            .flatMap { $0 as? Bool } ?? true
        defaultMaxDownloadsKept = defaults.object(forKey: Self.maxDownloadsKey)
            .flatMap { $0 as? Int } ?? 0
        defaultAutoDeleteListenedAfterDays = defaults.object(forKey: Self.autoDeleteDaysKey)
            .flatMap { $0 as? Int } ?? -1
        defaultAutoTranscribeOnDownload = defaults.object(forKey: Self.autoTranscribeKey)
            .flatMap { $0 as? Bool } ?? false
        defaultSpeed = defaults.object(forKey: Self.defaultSpeedKey).flatMap { $0 as? Double } ?? 1.0
        defaultVoiceBoost = defaults.object(forKey: Self.defaultBoostKey).flatMap { $0 as? Int } ?? 0
        defaultSkipSilence = defaults.object(forKey: Self.defaultSkipSilenceKey).flatMap { $0 as? Bool } ?? false
        defaultAdSkipMode = defaults.string(forKey: Self.defaultAdSkipKey) ?? "off"
        defaultAutoDownload = defaults.object(forKey: Self.defaultAutoDownloadKey).flatMap { $0 as? Bool } ?? false
        seekForwardSec = defaults.object(forKey: Self.seekForwardKey).flatMap { $0 as? Int } ?? 30
        seekBackSec = defaults.object(forKey: Self.seekBackKey).flatMap { $0 as? Int } ?? 15
        smartResumeEnabled = defaults.object(forKey: Self.smartResumeKey).flatMap { $0 as? Bool } ?? true
        autoplayNext = defaults.object(forKey: Self.autoplayNextKey).flatMap { $0 as? Bool } ?? true
        seekAccelerationEnabled = defaults.object(forKey: Self.seekAccelKey).flatMap { $0 as? Bool } ?? true
        wifiOnlyDownloads = defaults.object(forKey: Self.wifiOnlyKey).flatMap { $0 as? Bool } ?? true
    }
}
