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

    func configureRemoteCommands(play: @escaping @MainActor () -> Void,
                                 pause: @escaping @MainActor () -> Void,
                                 skipForward: @escaping @MainActor () -> Void,
                                 skipBack: @escaping @MainActor () -> Void) {
        // Remote commands can arrive on a non-main MediaRemote queue — hop, never assume.
        center.playCommand.addTarget { _ in Task { @MainActor in play() }; return .success }
        center.pauseCommand.addTarget { _ in Task { @MainActor in pause() }; return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in Task { @MainActor in skipForward() }; return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in Task { @MainActor in skipBack() }; return .success }
    }

    func configureBookmarkCommand(_ handler: @escaping @MainActor () -> Void) {
        let cmd = MPRemoteCommandCenter.shared().bookmarkCommand
        cmd.isEnabled = true
        cmd.addTarget { _ in Task { @MainActor in handler() }; return .success }
    }

    func update(title: String, show: String, position: TimeInterval, duration: TimeInterval, rate: Float) {
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Called once per episode change. Fetched asynchronously and cached by URL — `update` runs
    // on every playback tick, so the artwork image must not be re-downloaded/re-decoded that often.
    func prepareArtwork(url: URL?) {
        artworkURL = url
        currentArtwork = url.flatMap { artworkCache[$0] }
        guard let url, currentArtwork == nil else { return }
        Task { [weak self] in
            guard let self, let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artworkCache[url] = artwork
            guard self.artworkURL == url else { return }
            self.currentArtwork = artwork
        }
    }
}
