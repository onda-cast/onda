//  ShowSettings.swift
import Foundation
import SwiftData

@Model
final class ShowSettings {
    // Playback overrides — nil inherits the AppSettings global default.
    var speed: Double?
    var voiceBoost: Int?        // 0 = Off, 1 = Med, 2 = High
    var skipSilence: Bool?
    var adSkipMode: String?     // "off" | "manual" | "auto"
    var autoDownload: Bool?
    var introTrimSec: Int
    var outroTrimSec: Int
    // Retention overrides — nil inherits the AppSettings global default.
    var maxDownloadsKeptOverride: Int?              // 0 = explicitly unlimited
    var autoDeleteListenedAfterDaysOverride: Int?   // -1 = explicitly off, 0 = immediately
    var autoTranscribeOnDownloadOverride: Bool?
    var keepTranscriptsOverride: Bool?
    var ttsVoiceIdentifier: String?   // Articles show only; nil = system default voice
    var podcast: Podcast?

    init(speed: Double? = nil, voiceBoost: Int? = nil, skipSilence: Bool? = nil,
         adSkipMode: String? = nil, autoDownload: Bool? = nil,
         introTrimSec: Int = 0, outroTrimSec: Int = 0) {
        self.speed = speed
        self.voiceBoost = voiceBoost
        self.skipSilence = skipSilence
        self.adSkipMode = adSkipMode
        self.autoDownload = autoDownload
        self.introTrimSec = introTrimSec
        self.outroTrimSec = outroTrimSec
    }

    /// Fresh settings that inherit every global default (all overrides nil).
    static func makeDefault() -> ShowSettings { ShowSettings() }
}
