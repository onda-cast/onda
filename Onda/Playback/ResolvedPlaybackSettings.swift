//  ResolvedPlaybackSettings.swift
//  The single resolution point for playback-affecting settings: per-show override (non-nil
//  ShowSettings field) wins, otherwise the AppSettings global default. Everything that acts on
//  these values — PlaybackManager, FeedRefreshService, the settings UI captions — goes through
//  this type rather than reading ShowSettings fields directly.
import Foundation

@MainActor
struct ResolvedPlaybackSettings {
    let speed: Double
    let voiceBoost: Int
    let skipSilence: Bool
    let adSkipMode: String
    let autoDownload: Bool

    init(show: ShowSettings?, app: AppSettings) {
        speed = show?.speed ?? app.defaultSpeed
        voiceBoost = show?.voiceBoost ?? app.defaultVoiceBoost
        skipSilence = show?.skipSilence ?? app.defaultSkipSilence
        adSkipMode = show?.adSkipMode ?? app.defaultAdSkipMode
        autoDownload = show?.autoDownload ?? app.defaultAutoDownload
    }
}
