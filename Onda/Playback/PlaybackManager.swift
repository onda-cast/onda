//  PlaybackManager.swift
import Foundation
import SwiftData
import AVFoundation
import UIKit

/// Owns audio playback for the whole app: the transport (play / pause / seek), the canonical
/// playback position, the cross-show queue, and the sleep timer, plus the bridges out to the lock
/// screen (``NowPlayingCenter``) and the audio effects (Voice Boost, skip-silence, ad-skip,
/// intro/outro trim). Injected app-wide as an `@Observable` singleton; SwiftUI views read its
/// published state directly. Every playback-affecting setting resolves from the current episode's
/// `ShowSettings`.
///
/// - Important: `positionSeconds`/`durationSeconds` and all seeks are in **original feed seconds**
///   (the canonical timeline). Trim and skip-silence change what wall-clock maps to a feed second
///   but never the stored/displayed position.
@MainActor
@Observable
final class PlaybackManager {
    private let engine: PlayerEngine
    private let modelContext: ModelContext
    private let appSettings: AppSettings

    /// The episode currently loaded in the player, or `nil` before anything has played.
    var currentEpisode: Episode?
    /// Whether the transport is currently playing (as opposed to paused/stopped).
    var isPlaying: Bool = false
    /// Current playback position, in feed-seconds. Persisted to `Episode.playbackPosition` ~every 5s.
    var positionSeconds: TimeInterval = 0
    /// Duration of the current episode, in feed-seconds.
    var durationSeconds: TimeInterval = 0

    private var lastPersistedAt: TimeInterval = -100
    // Internal (not private) so UITestSeed can clear it: a restored mini-player from a previous
    // test's playback would otherwise make seeded launches nondeterministic.
    static let lastEpisodeKey = "lastPlayedEpisodeGuid"
    private let nowPlaying = NowPlayingCenter()
    var adActive: Bool = false
    private var silence = SilenceDetector()
    private var lastSilenceDiagAt: Double = 0
    private var seekAccelerator = SeekAccelerator()
    private var pausedAt: Date?

    init(engine: PlayerEngine, modelContext: ModelContext, appSettings: AppSettings) {
        self.engine = engine
        self.modelContext = modelContext
        self.appSettings = appSettings
        engine.onTimeUpdate = { [weak self] t in self?.handleTimeUpdate(t) }
        engine.onEndOfItem = { [weak self] in self?.handleEndOfItem() }
        engine.onRMS = { [weak self] rms, secs in
            guard let self else { return }
            // Clip preview is a scoped audition of exact edges: never silence-skip during it
            // (an automatic skip is not a "manual" cancellation and would break the loop).
            guard self.clipPreviewRange == nil else { return }
            guard self.resolved.skipSilence else {
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
            skipForward: { [weak self] in self?.skipForward() },
            skipBack: { [weak self] in self?.skipBack() })
        nowPlaying.configureBookmarkCommand { [weak self] in self?.onCaptureRequested?() }
        refreshSkipIntervals()
        observeInterruptions()
    }

    // Set when an audio-session interruption pauses us mid-play — consumed when it ends.
    private var resumeAfterInterruption = false

    // Wired in OndaApp: streaming an un-downloaded episode also saves it for offline (idempotent).
    var ensureDownloaded: ((Episode) -> Void)?

    // MARK: Capture (lock-screen quick clip)
    var onCaptureRequested: (() -> Void)?
    var captureToast: String?
    /// The clip a quick-capture (lock-screen bookmark) just created, if any — lets the capture
    /// toast be tappable into the same Review sheet the in-player scissors flow always forces,
    /// so both capture paths land in the same place instead of one being a silent fire-and-forget.
    var lastQuickClip: Clip?
    private var toastTask: Task<Void, Never>?

    /// Shows an app-wide confirmation toast (auto-dismissed after 2s) with a success haptic — used
    /// when a clip is captured, including from the lock-screen bookmark command.
    func showCaptureToast(_ text: String) {
        captureToast = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)   // felt when foregrounded
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.captureToast = nil
            self?.lastQuickClip = nil
        }
    }

    private func resumeExternally() { guard !isPlaying, currentEpisode != nil else { return }; togglePlayPause() }
    private func pauseExternally() { guard isPlaying else { return }; togglePlayPause() }

    // MARK: Mini-player coordination
    /// True while a scroll surface (Discover) wants the mini-player out of the way; RootView
    /// animates it off. Reset on tab switch and whenever playback starts.
    var miniPlayerHidden = false
    /// True while an active search wants the whole bottom chrome (tab bar included) out of the
    /// way of the keyboard and results; RootView animates it off. Restored when search focus ends
    /// (the tap-anywhere / scroll keyboard dismissal in DiscoverView), so the bar is never
    /// stranded off-screen.
    var tabBarHidden = false

    // MARK: Jump-from-transcript coordination
    // Bound to RootView's Now Playing sheet, so a transcript jump can surface the player.
    var showNowPlaying = false
    // Bumped on a jump; TranscriptView and ShowTranscriptsView dismiss themselves when it changes.
    private(set) var transcriptJumpNonce = 0
    // Set after a jump → the "Back to transcript" button shows in the player. Persists until the
    // user taps it or a different episode starts (cleared in play()); no timed disappearance.
    var returnToTranscriptEpisode: Episode?
    private var transcriptReturnTask: Task<Void, Never>?

    /// Jump to a transcript line and land in the player: seek 1s before the line, dismiss the
    /// transcript sheet(s), open Now Playing, and offer a persistent "back to transcript" button.
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
        }
    }

    /// Dismisses the pending "back to transcript" affordance (the user tapped it or it's no longer
    /// relevant), clearing ``returnToTranscriptEpisode``.
    func clearTranscriptReturn() {
        transcriptReturnTask?.cancel()
        returnToTranscriptEpisode = nil
    }

    private var settings: ShowSettings? { currentEpisode?.podcast?.settings }
    /// Effective playback settings for the current episode: per-show override ?? global default.
    var resolved: ResolvedPlaybackSettings {
        ResolvedPlaybackSettings(show: settings, app: appSettings)
    }
    /// Injectable clock (Smart Resume + seek acceleration are time-window behaviors).
    var now: () -> Date = { .now }
    /// Playback progress as a fraction `0...1` (position ÷ duration); `0` when nothing is loaded.
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    private var clipEndBound: TimeInterval?

    // MARK: Clip preview (Clip Review sheet)
    // Scoped, looping playback of a candidate clip range. Opening the sheet snapshots the
    // listener's spot (episode/position/play-state); closing restores it, so previewing can
    // never lose their place. While a preview is active, ticks do nothing but loop.
    private var clipPreviewRange: (start: TimeInterval, end: TimeInterval)?
    private var preClipPreview: (episode: Episode?, position: TimeInterval, wasPlaying: Bool)?

    /// Snapshot of the listener's spot, taken lazily on the FIRST ``previewRange(...)`` call —
    /// merely opening the clip editor must not stop whatever is playing (you might be editing a
    /// clip of a different episode than the one in your ears). Balanced by ``endClipPreview()``.
    func beginClipPreview() {
        guard preClipPreview == nil else { return }   // already in a preview; first snapshot wins
        preClipPreview = (currentEpisode, positionSeconds, isPlaying)
        engine.pause()
        isPlaying = false
        persistPosition()
    }

    /// Plays just `[start, end)` of `episode`, looping back to `start` at the end bound.
    /// Loads the episode (without auto-download) when it isn't the current one. The first call
    /// snapshots the listener's spot so dismissing the editor restores it.
    func previewRange(episode: Episode, start: TimeInterval, end: TimeInterval) {
        beginClipPreview()
        if currentEpisode?.guid != episode.guid { play(episode, autoDownload: false) }
        engine.seek(to: start)
        positionSeconds = start
        clipPreviewRange = (start, end)
        engine.play()
        isPlaying = true
    }

    /// Stops preview playback, leaving the playhead where it is (used by the sheet's stop
    /// button, and by "Set to playhead" which reads ``positionSeconds`` afterwards).
    func stopPreviewPlayback() {
        clipPreviewRange = nil
        engine.pause()
        isPlaying = false
    }

    /// Called when the Clip Review sheet dismisses: restore the pre-preview episode and
    /// position, resuming only if the listener was playing.
    func endClipPreview() {
        clipPreviewRange = nil
        guard let snapshot = preClipPreview else { return }
        preClipPreview = nil
        guard let ep = snapshot.episode else {
            // Nothing was loaded before the sheet (e.g. editing from the Clips list on a
            // fresh launch): just stop; the clip's episode stays loaded, paused.
            engine.pause()
            isPlaying = false
            return
        }
        if currentEpisode?.guid != ep.guid { play(ep, autoDownload: false) }
        engine.seek(to: snapshot.position)
        positionSeconds = snapshot.position
        if snapshot.wasPlaying {
            engine.play()
            isPlaying = true
        } else {
            engine.pause()
            isPlaying = false
        }
        persistPosition()
    }

    /// Plays a clip's bounded range: loads its episode, seeks to `clip.startTime`, and stops
    /// playback at `clip.endTime` without marking the episode played or advancing the queue.
    func playClip(_ clip: Clip) {
        guard let ep = clip.episode else { return }
        play(ep, autoDownload: false)     // clears any prior bound; a clip tap shouldn't pull the whole file
        engine.seek(to: clip.startTime)
        positionSeconds = clip.startTime
        clipEndBound = clip.endTime
    }

    /// Loads and starts an episode from its resume position (respecting the show's intro trim),
    /// applying the show's speed/boost/skip-silence settings and updating the lock screen.
    /// - Parameter autoDownload: when `true` (default) a streamed (not-yet-downloaded) episode is
    ///   also saved for offline in the background via the wired `ensureDownloaded`.
    func play(_ episode: Episode, autoDownload: Bool = true) {
        clipEndBound = nil
        clipPreviewRange = nil
        pausedAt = nil                    // a new episode isn't a resume — no Smart Resume rewind
        returnToTranscriptEpisode = nil   // a new episode invalidates the pending transcript return
        miniPlayerHidden = false          // starting playback always surfaces the mini-player
        currentEpisode = episode
        UserDefaults.standard.set(episode.guid, forKey: Self.lastEpisodeKey)  // restored on next launch
        durationSeconds = episode.duration
        nowPlaying.prepareArtwork(url: episode.podcast?.artworkURL)
        let intro = TimeInterval(settings?.introTrimSec ?? 0)
        let start = max(episode.playbackPosition, intro)
        let local = localURL(for: episode)
        let url = local ?? episode.audioURL
        engine.load(url: url, startAt: start)
        engine.rate = Float(resolved.speed)
        positionSeconds = start
        applyAudioSettings()
        silence.reset()
        engine.play()
        isPlaying = true
        // Streaming a remote episode: save it for offline in the background (idempotent).
        if autoDownload, local == nil { ensureDownloaded?(episode) }
    }

    /// Re-reads the current show's speed, Voice Boost, and skip-silence settings and applies them
    /// to the engine. Call after changing any of those while an episode is loaded.
    /// On a cold launch, re-loads the last-played episode into the player **paused** (no autoplay),
    /// so the mini-player reappears on the Library page ready to resume from the saved position.
    /// No-op if something is already loaded or nothing was ever played.
    func restoreLastEpisode() {
        guard currentEpisode == nil,
              let guid = UserDefaults.standard.string(forKey: Self.lastEpisodeKey) else { return }
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        guard let episode = try? modelContext.fetch(descriptor).first else { return }
        currentEpisode = episode
        durationSeconds = episode.duration
        let start = max(episode.playbackPosition, TimeInterval(settings?.introTrimSec ?? 0))
        positionSeconds = start
        nowPlaying.prepareArtwork(url: episode.podcast?.artworkURL)
        engine.load(url: localURL(for: episode) ?? episode.audioURL, startAt: start)
        engine.rate = Float(resolved.speed)
        // Intentionally paused: isPlaying stays false until the user taps play.
    }

    func applyAudioSettings() {
        let r = resolved
        engine.rate = Float(r.speed)
        let boost = BoostLevel(clamping: r.voiceBoost)
        engine.setBoostGain(boost.gain)
        if !r.skipSilence { silence.reset() }
        tapLog.notice("""
            audio settings applied: speed=\(r.speed) \
            boost=\(boost.rawValue) skipSilence=\(r.skipSilence)
            """)
    }

    private func adWindow(for ep: Episode) -> AdWindow {
        AdWindow(chapters: ep.chapters.map { ($0.startTime, $0.isAd) }, duration: ep.duration)
    }

    /// Toggles between play and pause for the current episode (no-op when nothing is loaded).
    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying {
            engine.pause(); persistPosition()
            pausedAt = now()
        } else {
            if appSettings.smartResumeEnabled, let pausedAt {
                let rewind = Self.smartResumeRewind(afterPauseOf: now().timeIntervalSince(pausedAt))
                if rewind > 0 {
                    let target = max(0, positionSeconds - rewind)
                    engine.seek(to: target); positionSeconds = target
                }
            }
            pausedAt = nil
            engine.play()
        }
        isPlaying.toggle()
    }

    /// Seeks relative to the current position by `seconds` (negative to go back), clamped to the
    /// episode bounds. Cancels any active clip end-bound.
    func skip(by seconds: TimeInterval) {
        clipEndBound = nil
        clipPreviewRange = nil
        let target = max(0, min(durationSeconds, positionSeconds + seconds))
        engine.seek(to: target); positionSeconds = target
    }

    /// Seeks to a fraction `0...1` of the episode duration (the scrubber's seek path).
    func seek(toFraction f: Double) {
        clipEndBound = nil
        clipPreviewRange = nil
        let target = max(0, min(durationSeconds, durationSeconds * f))
        engine.seek(to: target); positionSeconds = target
    }

    /// The on-disk URL of `episode`'s downloaded audio, or `nil` if it isn't downloaded. Checks the
    /// `downloadedFile` relationship first, then the guid-derived path — the relationship can be
    /// stale within a session because downloads persist via a separate `@ModelActor` context.
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

        // Clip preview: bounce back to the range start at the end bound; skip everything
        // else (persist, played-marking, ads, outro) — preview must not touch stored state.
        if let range = clipPreviewRange {
            if t >= range.end {
                engine.seek(to: range.start)
                positionSeconds = range.start
            }
            return
        }

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
            if adActive, resolved.adSkipMode == "auto", let end = w.adEnd(at: t), end > t {
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
                          rate: isPlaying ? Float(resolved.speed) : 0)
    }

    private func persistPosition() {
        guard let ep = currentEpisode else { return }
        ep.playbackPosition = positionSeconds
        lastPersistedAt = positionSeconds
        try? modelContext.save()
    }

    /// Called when the current episode reaches its (trimmed) end: marks it played, then either
    /// stops for an end-of-episode sleep timer or advances to the next queued/unplayed episode.
    func handleEndOfItem() {
        // A preview range ending at the episode's true end reaches the native end-of-item
        // before a time tick can loop it — loop here too, never mark played / advance the queue.
        if let range = clipPreviewRange {
            engine.seek(to: range.start); positionSeconds = range.start; return
        }
        if let ep = currentEpisode { ep.played = true; ep.playedDate = .now; ep.playbackPosition = 0 }
        try? modelContext.save()
        if sleepMode == .endOfEpisode {
            isPlaying = false
            sleepMode = .off
            return
        }
        if !appSettings.autoplayNext {
            isPlaying = false
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
    private(set) var sleepFireDate: Date?

    /// Seconds left on a duration sleep timer, or nil when none is armed.
    var sleepRemaining: TimeInterval? {
        guard let d = sleepFireDate else { return nil }
        return max(0, d.timeIntervalSinceNow)
    }
}

// MARK: - Configured skips (seek intervals, acceleration, Smart Resume)
extension PlaybackManager {
    /// Smart Resume rewind: after a break, back up a little so the listener regains context.
    /// Fixed internal thresholds (not user-tunable); the feature toggle lives in AppSettings.
    static func smartResumeRewind(afterPauseOf pause: TimeInterval) -> TimeInterval {
        switch pause {
        case ..<60: 0
        case ..<(30 * 60): 5
        case ..<(3 * 3600): 15
        default: 30
        }
    }

    /// User-facing skip actions (player buttons, lock screen). Use the configured intervals —
    /// accelerated on rapid repeat taps; internal seeks (ads, silence, chapters) call `skip(by:)`.
    func skipForward() {
        let mult = appSettings.seekAccelerationEnabled
            ? seekAccelerator.multiplier(direction: 1, now: now()) : 1
        skip(by: TimeInterval(appSettings.seekForwardSec) * mult)
    }

    func skipBack() {
        let mult = appSettings.seekAccelerationEnabled
            ? seekAccelerator.multiplier(direction: -1, now: now()) : 1
        skip(by: -TimeInterval(appSettings.seekBackSec) * mult)
    }

    /// Pushes the configured intervals to the lock-screen remote commands.
    func refreshSkipIntervals() {
        nowPlaying.updateSkipIntervals(forward: appSettings.seekForwardSec,
                                       back: appSettings.seekBackSec)
    }
}

// MARK: - Queue + sleep timer
extension PlaybackManager {
    /// Appends an episode to the end of the cross-show queue (no-op if already queued).
    func enqueue(_ episode: Episode) {
        guard !queue.contains(where: { $0.guid == episode.guid }) else { return }
        let item = QueueItem(episode: episode, position: queue.count)
        modelContext.insert(item)
        queue.append(episode)
        try? modelContext.save()
    }

    /// Removes an episode from the queue and re-persists the queue order.
    func removeFromQueue(_ episode: Episode) {
        queue.removeAll { $0.guid == episode.guid }
        let guid = episode.guid
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for it in items where it.episode?.guid == guid { modelContext.delete(it) }
        reindexQueue()
    }

    /// Reorders the queue (drag-to-reorder) and persists the new positions.
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

    /// Tapping a queue item jumps to it; everything else stays queued in order.
    func playFromQueue(_ episode: Episode) {
        // Only the tapped item leaves the queue. Skipped-over episodes stay put (they play after
        // this one) — silently dropping them was surprising and unrecoverable.
        removeFromQueue(episode)
        play(episode)
    }

    /// Plays the next episode: the head of the queue if non-empty, otherwise the newest unplayed
    /// episode of the current show; stops playback when neither exists.
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

    /// Replaces the queue with `episodes` and starts playing the first one — the materialization
    /// path for a smart queue (Unplayed, Downloaded, …) tapped in Library.
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

    /// Arms (or clears, with `.off`) the sleep timer. `.duration` pauses after N seconds;
    /// `.endOfEpisode` pauses when the current episode finishes.
    func setSleepTimer(_ mode: SleepMode) {
        sleepMode = mode
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepFireDate = nil
        if case let .duration(seconds) = mode {
            sleepFireDate = Date().addingTimeInterval(seconds)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                Task { @MainActor [weak self] in self?.fireSleepTimer() }
            }
        }
    }

    // Always clears the armed state (even if paused when it fires) so the icon never lies.
    private func fireSleepTimer() {
        if isPlaying { togglePlayPause() }
        sleepMode = .off
        sleepFireDate = nil
        sleepTimer = nil
    }
}

// MARK: - Mini-player dismissal + audio-session interruptions
extension PlaybackManager {
    /// Swipe-to-dismiss on the mini-player: stop playback and remove the bar. The queue survives;
    /// the saved last-episode guid is cleared so an explicitly closed player doesn't come back on
    /// the next launch.
    func dismissPlayer() {
        if isPlaying { engine.pause(); persistPosition() }
        isPlaying = false
        setSleepTimer(.off)
        currentEpisode = nil
        returnToTranscriptEpisode = nil
        UserDefaults.standard.removeObject(forKey: Self.lastEpisodeKey)
    }

    /// Another app taking exclusive audio (a call, Siri, a non-mixing app) interrupts our session
    /// and the system pauses playback. Mirror that in our state, and — Overcast-style — resume
    /// automatically when the interruption ends carrying the system's `shouldResume` hint.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance(),
                                               queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: type, optionsRaw: opts) }
        }
    }

    /// Internal (not private) so tests can drive interruption sequences with raw values.
    func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying {
                engine.pause()   // usually already paused by the system; keep engine+state in sync
                isPlaying = false
                persistPosition()
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if resumeAfterInterruption, opts.contains(.shouldResume), currentEpisode != nil {
                engine.play()
                isPlaying = true
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }
}
