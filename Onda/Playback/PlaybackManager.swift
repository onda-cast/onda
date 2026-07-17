//  PlaybackManager.swift
import Foundation
import SwiftData
import AVFoundation

@MainActor
@Observable
final class PlaybackManager {
    private let engine: PlayerEngine
    private let modelContext: ModelContext

    var currentEpisode: Episode?
    var isPlaying: Bool = false
    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0

    private var lastPersistedAt: TimeInterval = -100
    private let nowPlaying = NowPlayingCenter()
    var adActive: Bool = false
    private var silence = SilenceDetector()

    init(engine: PlayerEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext
        engine.onTimeUpdate = { [weak self] t in self?.handleTimeUpdate(t) }
        engine.onEndOfItem = { [weak self] in self?.handleEndOfItem() }
        engine.onRMS = { [weak self] rms, secs in
            guard let self, self.settings?.skipSilence == true else { return }
            if let skip = self.silence.consume(rms: rms, bufferSeconds: secs) {
                tapLog.info("skip-silence triggered: jumping \(skip.seconds, format: .fixed(precision: 2))s")
                self.skip(by: skip.seconds)
            }
        }
        nowPlaying.configureRemoteCommands(
            play: { [weak self] in self?.resumeExternally() },
            pause: { [weak self] in self?.pauseExternally() },
            skipForward: { [weak self] in self?.skip(by: 30) },
            skipBack: { [weak self] in self?.skip(by: -15) })
        nowPlaying.configureBookmarkCommand { [weak self] in self?.onCaptureRequested?() }
    }

    // MARK: Capture (lock-screen quick clip)
    var onCaptureRequested: (() -> Void)?
    var captureToast: String?
    private var toastTask: Task<Void, Never>?

    func showCaptureToast(_ text: String) {
        captureToast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.captureToast = nil
        }
    }

    private func resumeExternally() { guard !isPlaying, currentEpisode != nil else { return }; togglePlayPause() }
    private func pauseExternally() { guard isPlaying else { return }; togglePlayPause() }

    private var settings: ShowSettings? { currentEpisode?.podcast?.settings }
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    private var clipEndBound: TimeInterval?

    func playClip(_ clip: Clip) {
        guard let ep = clip.episode else { return }
        play(ep)                          // clears any prior bound
        engine.seek(to: clip.startTime)
        positionSeconds = clip.startTime
        clipEndBound = clip.endTime
    }

    func play(_ episode: Episode) {
        clipEndBound = nil
        currentEpisode = episode
        durationSeconds = episode.duration
        let intro = TimeInterval(settings?.introTrimSec ?? 0)
        let start = max(episode.playbackPosition, intro)
        let url = localURL(for: episode) ?? episode.audioURL
        engine.load(url: url, startAt: start)
        engine.rate = Float(settings?.speed ?? 1.0)
        positionSeconds = start
        applyAudioSettings()
        silence.reset()
        engine.play()
        isPlaying = true
    }

    func applyAudioSettings() {
        engine.rate = Float(settings?.speed ?? 1.0)
        let boost = BoostLevel(clamping: settings?.voiceBoost ?? 0)
        engine.setBoostGain(boost.gain)
        if settings?.skipSilence != true { silence.reset() }
    }

    private func adWindow(for ep: Episode) -> AdWindow {
        AdWindow(chapters: ep.chapters.map { ($0.startTime, $0.isAd) }, duration: ep.duration)
    }

    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying { engine.pause(); persistPosition() }
        else { engine.play() }
        isPlaying.toggle()
    }

    func skip(by seconds: TimeInterval) {
        clipEndBound = nil
        let target = max(0, min(durationSeconds, positionSeconds + seconds))
        engine.seek(to: target); positionSeconds = target
    }

    func seek(toFraction f: Double) {
        clipEndBound = nil
        let target = max(0, min(durationSeconds, durationSeconds * f))
        engine.seek(to: target); positionSeconds = target
    }

    // Resolve a downloaded file to a playable URL. Checks the relationship first, then
    // falls back to the guid-derived path on disk — the relationship can be stale within
    // a session because downloads persist via a separate @ModelActor context.
    func localURL(for episode: Episode) -> URL? {
        if let name = episode.downloadedFile?.localFileName {
            let url = DownloadManager.fileURL(named: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let byGuid = DownloadManager.fileURL(named: DownloadManager.fileName(for: episode.guid))
        return FileManager.default.fileExists(atPath: byGuid.path) ? byGuid : nil
    }

    private func handleTimeUpdate(_ t: TimeInterval) {
        positionSeconds = t
        guard let ep = currentEpisode else { return }

        // Clip-bounded playback: stop at the clip end without marking played/advancing.
        if let bound = clipEndBound, t >= bound {
            clipEndBound = nil
            engine.pause()
            isPlaying = false
            persistPosition()
            return
        }

        // Ad detection from real Podcasting 2.0 markers; auto mode seeks past the ad.
        if !ep.chapters.isEmpty {
            let w = adWindow(for: ep)
            adActive = w.isAd(at: t)
            if adActive, settings?.adSkipMode == "auto", let end = w.adEnd(at: t), end > t {
                engine.seek(to: end); positionSeconds = end; adActive = false
            }
        } else {
            adActive = false
        }

        // Outro trim: treat (duration - outro) as the effective end.
        let outro = TimeInterval(settings?.outroTrimSec ?? 0)
        if outro > 0, t >= ep.duration - outro { handleEndOfItem(); return }

        if t - lastPersistedAt >= 5 { persistPosition() }
        if ep.duration > 0, t >= ep.duration * 0.95, !ep.played {
            ep.played = true; try? modelContext.save()
        }
        nowPlaying.update(title: ep.title, show: ep.podcast?.title ?? "",
                          position: positionSeconds, duration: durationSeconds,
                          rate: isPlaying ? Float(settings?.speed ?? 1.0) : 0)
    }

    private func persistPosition() {
        guard let ep = currentEpisode else { return }
        ep.playbackPosition = positionSeconds
        lastPersistedAt = positionSeconds
        try? modelContext.save()
    }

    func handleEndOfItem() {
        if let ep = currentEpisode { ep.played = true; ep.playbackPosition = 0 }
        try? modelContext.save()
        if sleepMode == .endOfEpisode {
            isPlaying = false
            sleepMode = .off
            return
        }
        playNextInQueue()
    }

    // MARK: Queue
    private(set) var queue: [Episode] = []

    func enqueue(_ episode: Episode) {
        guard !queue.contains(where: { $0.guid == episode.guid }) else { return }
        let item = QueueItem(episode: episode, position: queue.count)
        modelContext.insert(item)
        queue.append(episode)
        try? modelContext.save()
    }

    func removeFromQueue(_ episode: Episode) {
        queue.removeAll { $0.guid == episode.guid }
        let guid = episode.guid
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for it in items where it.episode?.guid == guid { modelContext.delete(it) }
        reindexQueue()
    }

    func moveQueue(from: IndexSet, to: Int) {
        queue.move(fromOffsets: from, toOffset: to)
        reindexQueue()
    }

    private func reindexQueue() {
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for ep in queue.enumerated() {
            items.first { $0.episode?.guid == ep.element.guid }?.position = ep.offset
        }
        try? modelContext.save()
    }

    private func playNextInQueue() {
        if !queue.isEmpty {
            let next = queue[0]
            removeFromQueue(next)
            play(next)
            return
        }
        if let show = currentEpisode?.podcast,
           let next = show.episodes
               .filter({ !$0.played && $0.guid != currentEpisode?.guid })
               .sorted(by: { $0.publishDate > $1.publishDate }).first {
            play(next)
            return
        }
        isPlaying = false
    }

    // MARK: Sleep timer
    enum SleepMode: Equatable { case off, duration(TimeInterval), endOfEpisode }
    var sleepMode: SleepMode = .off
    private var sleepTimer: Timer?

    func setSleepTimer(_ mode: SleepMode) {
        sleepMode = mode
        sleepTimer?.invalidate(); sleepTimer = nil
        if case let .duration(seconds) = mode {
            sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.togglePlayPause()
                    self.sleepMode = .off
                }
            }
        }
    }
}
