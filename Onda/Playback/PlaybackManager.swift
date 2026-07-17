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
    private var lastSilenceDiagAt: Double = 0

    init(engine: PlayerEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext
        engine.onTimeUpdate = { [weak self] t in self?.handleTimeUpdate(t) }
        engine.onEndOfItem = { [weak self] in self?.handleEndOfItem() }
        engine.onRMS = { [weak self] rms, secs in
            guard let self else { return }
            guard self.settings?.skipSilence == true else {
                if CFAbsoluteTimeGetCurrent() - self.lastSilenceDiagAt > 10 {
                    self.lastSilenceDiagAt = CFAbsoluteTimeGetCurrent()
                    tapLog.notice("silence detector idle: skipSilence setting is OFF for this show")
                }
                return
            }
            if let skip = self.silence.consume(rms: rms, bufferSeconds: secs) {
                tapLog.notice("skip-silence triggered: jumping \(skip.seconds, format: .fixed(precision: 2))s")
                self.skip(by: skip.seconds)
            } else if CFAbsoluteTimeGetCurrent() - self.lastSilenceDiagAt > 10 {
                self.lastSilenceDiagAt = CFAbsoluteTimeGetCurrent()
                let longest = self.silence.longestRunSeconds
                let need = self.silence.minSilenceSeconds
                tapLog.notice("""
                    silence detector armed: longest quiet run so far \
                    \(longest, format: .fixed(precision: 2))s (need \(need, format: .fixed(precision: 1))s)
                    """)
            }
        }
        nowPlaying.configureRemoteCommands(
            play: { [weak self] in self?.resumeExternally() },
            pause: { [weak self] in self?.pauseExternally() },
            skipForward: { [weak self] in self?.skip(by: 30) },
            skipBack: { [weak self] in self?.skip(by: -15) })
        nowPlaying.configureBookmarkCommand { [weak self] in self?.onCaptureRequested?() }
    }

    // Wired in OndaApp: streaming an un-downloaded episode also saves it for offline (idempotent).
    var ensureDownloaded: ((Episode) -> Void)?

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

    // MARK: Jump-from-transcript coordination
    // Bound to RootView's Now Playing sheet, so a transcript jump can surface the player.
    var showNowPlaying = false
    // Bumped on a jump; TranscriptView and ShowTranscriptsView dismiss themselves when it changes.
    private(set) var transcriptJumpNonce = 0
    // Non-nil for ~5s after a jump → the floating "Back to transcript" button shows in the player.
    var returnToTranscriptEpisode: Episode?
    private var transcriptReturnTask: Task<Void, Never>?

    /// Jump to a transcript line and land in the player: seek 1s before the line, dismiss the
    /// transcript sheet(s), open Now Playing, and offer a 5s "back to transcript" affordance.
    func jumpFromTranscript(episode: Episode, to start: TimeInterval) {
        let target = max(0, start - 1)
        if currentEpisode?.guid != episode.guid { play(episode) }
        seek(toFraction: target / max(1, episode.duration))
        transcriptJumpNonce += 1
        returnToTranscriptEpisode = episode
        transcriptReturnTask?.cancel()
        transcriptReturnTask = Task { @MainActor [weak self] in
            // Let the transcript sheet(s) dismiss before presenting the player (podcast-screen path).
            try? await Task.sleep(for: .milliseconds(400))
            self?.showNowPlaying = true
            try? await Task.sleep(for: .seconds(5))
            self?.returnToTranscriptEpisode = nil
        }
    }

    func clearTranscriptReturn() {
        transcriptReturnTask?.cancel()
        returnToTranscriptEpisode = nil
    }

    private var settings: ShowSettings? { currentEpisode?.podcast?.settings }
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    private var clipEndBound: TimeInterval?

    func playClip(_ clip: Clip) {
        guard let ep = clip.episode else { return }
        play(ep, autoDownload: false)     // clears any prior bound; a clip tap shouldn't pull the whole file
        engine.seek(to: clip.startTime)
        positionSeconds = clip.startTime
        clipEndBound = clip.endTime
    }

    func play(_ episode: Episode, autoDownload: Bool = true) {
        clipEndBound = nil
        currentEpisode = episode
        durationSeconds = episode.duration
        nowPlaying.prepareArtwork(url: episode.podcast?.artworkURL)
        let intro = TimeInterval(settings?.introTrimSec ?? 0)
        let start = max(episode.playbackPosition, intro)
        let local = localURL(for: episode)
        let url = local ?? episode.audioURL
        engine.load(url: url, startAt: start)
        engine.rate = Float(settings?.speed ?? 1.0)
        positionSeconds = start
        applyAudioSettings()
        silence.reset()
        engine.play()
        isPlaying = true
        // Streaming a remote episode: save it for offline in the background (idempotent).
        if autoDownload, local == nil { ensureDownloaded?(episode) }
    }

    func applyAudioSettings() {
        engine.rate = Float(settings?.speed ?? 1.0)
        let boost = BoostLevel(clamping: settings?.voiceBoost ?? 0)
        engine.setBoostGain(boost.gain)
        if settings?.skipSilence != true { silence.reset() }
        tapLog.notice("""
            audio settings applied: speed=\(self.settings?.speed ?? 1.0) \
            boost=\(boost.rawValue) skipSilence=\(self.settings?.skipSilence == true)
            """)
    }

    private func adWindow(for ep: Episode) -> AdWindow {
        AdWindow(chapters: ep.chapters.map { ($0.startTime, $0.isAd) }, duration: ep.duration)
    }

    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying { engine.pause(); persistPosition() } else { engine.play() }
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
            ep.played = true; ep.playedDate = .now; try? modelContext.save()
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
        if let ep = currentEpisode { ep.played = true; ep.playedDate = .now; ep.playbackPosition = 0 }
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

    // MARK: Sleep timer
    enum SleepMode: Equatable { case off, duration(TimeInterval), endOfEpisode }
    var sleepMode: SleepMode = .off
    fileprivate var sleepTimer: Timer?
}

// MARK: - Queue + sleep timer
extension PlaybackManager {
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

    func playNextInQueue() {
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

    func startSmartQueue(_ episodes: [Episode]) {
        guard let first = episodes.first else { return }
        clearQueue()
        for ep in episodes.dropFirst() {
            let item = QueueItem(episode: ep, position: queue.count)
            modelContext.insert(item)
            queue.append(ep)
        }
        try? modelContext.save()
        play(first)
    }

    private func clearQueue() {
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for it in items { modelContext.delete(it) }
        queue.removeAll()
    }

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
