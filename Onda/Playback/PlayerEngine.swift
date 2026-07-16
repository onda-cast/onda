//  PlayerEngine.swift
import AVFoundation

@MainActor
protocol PlayerEngine: AnyObject {
    var rate: Float { get set }
    var currentTimeSeconds: TimeInterval { get }
    var onEndOfItem: (() -> Void)? { get set }
    var onTimeUpdate: ((TimeInterval) -> Void)? { get set }
    func load(url: URL, startAt: TimeInterval)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
}

@MainActor
final class AVPlayerEngine: PlayerEngine {
    private let player = AVPlayer()
    private var timeObserver: Any?
    var onEndOfItem: (() -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?

    var rate: Float {
        get { player.rate }
        set { if player.timeControlStatus == .playing { player.rate = newValue } else { player.defaultRate = newValue } }
    }
    var currentTimeSeconds: TimeInterval { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func load(url: URL, startAt: TimeInterval) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if startAt > 0 { seek(to: startAt) }
        addObservers(for: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func addObservers(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEndOfItem?() }
        }
        if timeObserver == nil {
            let interval = CMTime(seconds: 1, preferredTimescale: 2)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.onTimeUpdate?(t.seconds.isFinite ? t.seconds : 0) }
            }
        }
    }
}
