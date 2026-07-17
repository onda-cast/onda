//  ShowSettings.swift
import Foundation
import SwiftData

@Model
final class ShowSettings {
    var speed: Double
    var voiceBoost: Int         // 0 = Off, 1 = Med, 2 = High
    var skipSilence: Bool
    var adSkipMode: String      // "off" | "manual" | "auto"
    var autoDownload: Bool
    var introTrimSec: Int
    var outroTrimSec: Int
    var notifMode: String       // "all" | "important" | "none"
    // Retention overrides — nil inherits the AppSettings global default.
    var maxDownloadsKeptOverride: Int?              // 0 = explicitly unlimited
    var autoDeleteListenedAfterDaysOverride: Int?   // -1 = explicitly off, 0 = immediately
    var autoTranscribeOnDownloadOverride: Bool?
    var keepTranscriptsOverride: Bool?
    var podcast: Podcast?

    init(speed: Double, voiceBoost: Int, skipSilence: Bool, adSkipMode: String,
         autoDownload: Bool, introTrimSec: Int, outroTrimSec: Int, notifMode: String) {
        self.speed = speed
        self.voiceBoost = voiceBoost
        self.skipSilence = skipSilence
        self.adSkipMode = adSkipMode
        self.autoDownload = autoDownload
        self.introTrimSec = introTrimSec
        self.outroTrimSec = outroTrimSec
        self.notifMode = notifMode
    }

    static func makeDefault() -> ShowSettings {
        ShowSettings(speed: 1.0, voiceBoost: 0, skipSilence: false, adSkipMode: "off",
                     autoDownload: false, introTrimSec: 0, outroTrimSec: 0, notifMode: "all")
    }
}
