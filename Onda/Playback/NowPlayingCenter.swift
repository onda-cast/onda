//  NowPlayingCenter.swift
import MediaPlayer
import AVFoundation
import UIKit

enum AudioSession {
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }
}

@MainActor
final class NowPlayingCenter {
    private let center = MPRemoteCommandCenter.shared()
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkURL: URL?
    // What the last full `update` actually wrote — lets subsequent same-episode ticks (title/
    // show/duration/artwork all unchanged, only position/rate moving) mutate the existing
    // Now Playing dictionary in place instead of reallocating and rewriting the whole thing
    // (including re-attaching artwork) roughly twice a second.
    private var lastTitle: String?
    private var lastShow: String?
    private var lastDuration: TimeInterval?
    private var lastAttachedArtwork: MPMediaItemArtwork?

    func configureRemoteCommands(play: @escaping @MainActor () -> Void,
                                 pause: @escaping @MainActor () -> Void,
                                 toggle: @escaping @MainActor () -> Void,
                                 skipForward: @escaping @MainActor () -> Void,
                                 skipBack: @escaping @MainActor () -> Void) {
        // Remote commands can arrive on a non-main MediaRemote queue — hop, never assume.
        center.playCommand.addTarget { _ in Task { @MainActor in play() }; return .success }
        center.pauseCommand.addTarget { _ in Task { @MainActor in pause() }; return .success }
        // AirPods/headset stem presses send togglePlayPauseCommand — NOT play/pause. Without
        // a target here iOS drops the press entirely (lock-screen buttons still worked, which
        // is how this went unnoticed).
        center.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in toggle() }; return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in Task { @MainActor in skipForward() }; return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in Task { @MainActor in skipBack() }; return .success }
        // AirPods double/triple press arrive as track commands; podcasts have no tracks, so
        // map them to the skip actions (the Overcast/Apple Podcasts convention).
        center.nextTrackCommand.addTarget { _ in Task { @MainActor in skipForward() }; return .success }
        center.previousTrackCommand.addTarget { _ in Task { @MainActor in skipBack() }; return .success }
    }

    /// Re-registers the lock-screen skip button intervals (called at startup and when the
    /// user changes the seek-interval setting).
    func updateSkipIntervals(forward: Int, back: Int) {
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: back)]
    }

    func configureBookmarkCommand(_ handler: @escaping @MainActor () -> Void) {
        let cmd = MPRemoteCommandCenter.shared().bookmarkCommand
        cmd.isEnabled = true
        cmd.addTarget { _ in Task { @MainActor in handler() }; return .success }
    }

    func update(title: String, show: String, position: TimeInterval, duration: TimeInterval, rate: Float) {
        let center = MPNowPlayingInfoCenter.default()
        let unchanged = title == lastTitle && show == lastShow && duration == lastDuration
            && currentArtwork === lastAttachedArtwork
        if unchanged, var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            center.nowPlayingInfo = info
            return
        }
        lastTitle = title; lastShow = show; lastDuration = duration; lastAttachedArtwork = currentArtwork
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: show,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        center.nowPlayingInfo = info
    }

    // Called once per episode change. Fetched asynchronously and cached by URL — `update` runs
    // on every playback tick, so the artwork image must not be re-downloaded/re-decoded that often.
    func prepareArtwork(url: URL?) {
        artworkURL = url
        currentArtwork = url.flatMap { artworkCache[$0] }
        guard let url, currentArtwork == nil else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let artwork = await Self.makeArtwork(from: data) else { return }
            guard let self, self.artworkURL == url else { return }
            self.artworkCache[url] = artwork
            self.currentArtwork = artwork
        }
    }

    // MUST be nonisolated. This whole type is main-actor isolated (SWIFT_DEFAULT_ACTOR_ISOLATION),
    // so a request-handler closure formed in main-actor code is inferred @MainActor-isolated — and
    // MediaPlayer invokes that handler on its own background accessQueue (jpegDataWithSize:) to
    // render lock-screen art. That off-main call trips the Swift runtime's executor assertion
    // (dispatch_assert_queue → EXC_BREAKPOINT), a device-only crash. Building the artwork here, in
    // a nonisolated context, gives the handler no isolation so it's callable from any queue. Data
    // is Sendable (safe in); byPreparingForDisplay force-decodes so no lazy decode races either.
    private nonisolated static func makeArtwork(from data: Data) async -> MPMediaItemArtwork? {
        guard let raw = UIImage(data: data) else { return nil }
        let image = await raw.byPreparingForDisplay() ?? raw
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
