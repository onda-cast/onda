//  PlayerEngine.swift
import AVFoundation

@MainActor
protocol PlayerEngine: AnyObject {
    var rate: Float { get set }
    var currentTimeSeconds: TimeInterval { get }
    var onEndOfItem: (() -> Void)? { get set }
    var onTimeUpdate: ((TimeInterval) -> Void)? { get set }
    var onRMS: ((Float, Double) -> Void)? { get set }
    func load(url: URL, startAt: TimeInterval)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func setBoostGain(_ gain: Float)
}

@MainActor
final class AVPlayerEngine: PlayerEngine {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var installTapTask: Task<Void, Never>?
    private var tap: AudioTap?
    var onEndOfItem: (() -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onRMS: ((Float, Double) -> Void)?

    func setBoostGain(_ gain: Float) {
        tap?.gain = gain
    }

    var rate: Float {
        get { player.rate }
        set { if player.timeControlStatus == .playing { player.rate = newValue } else { player.defaultRate = newValue } }
    }

    var currentTimeSeconds: TimeInterval {
        player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
    }

    func load(url: URL, startAt: TimeInterval) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if startAt > 0 { seek(to: startAt) }
        addObservers(for: item)
        installTap(on: item)
    }

    private func installTap(on item: AVPlayerItem) {
        // Cancel any still-running install for the PREVIOUS item — without this, a rapid
        // episode switch can let a stale task resolve after the new one and silently overwrite
        // `self.tap` with a tap bound to a discarded item, breaking Voice Boost/skip-silence
        // until the next switch.
        installTapTask?.cancel()
        installTapTask = Task { [weak self, weak item] in
            guard let item,
                  let track = try? await item.asset.loadTracks(withMediaCharacteristic: .audible).first
            else { return }
            guard let self, !Task.isCancelled, item === self.player.currentItem else { return }
            let t = AudioTap()
            t.gain = self.tap?.gain ?? 1.0   // carry the current boost across episodes
            t.onRMS = { rms, secs in
                Task { @MainActor [weak self] in self?.onRMS?(rms, secs) }
            }
            item.audioMix = t.makeAudioMix(for: track)
            self.tap = t
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func addObservers(for item: AVPlayerItem) {
        // Replace, don't accumulate — every load() previously registered a fresh end-of-item
        // observer for the outgoing item that was never removed, a small leak over a long
        // listening session.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
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
