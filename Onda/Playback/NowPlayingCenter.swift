//  NowPlayingCenter.swift
import MediaPlayer
import AVFoundation

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
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: show,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
