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

    init(engine: PlayerEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext
        engine.onTimeUpdate = { [weak self] t in self?.handleTimeUpdate(t) }
        engine.onEndOfItem = { [weak self] in self?.handleEndOfItem() }
        nowPlaying.configureRemoteCommands(
            play: { [weak self] in self?.resumeExternally() },
            pause: { [weak self] in self?.pauseExternally() },
            skipForward: { [weak self] in self?.skip(by: 30) },
            skipBack: { [weak self] in self?.skip(by: -15) })
    }

    private func resumeExternally() { guard !isPlaying, currentEpisode != nil else { return }; togglePlayPause() }
    private func pauseExternally() { guard isPlaying else { return }; togglePlayPause() }

    private var settings: ShowSettings? { currentEpisode?.podcast?.settings }
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    func play(_ episode: Episode) {
        currentEpisode = episode
        durationSeconds = episode.duration
        let intro = TimeInterval(settings?.introTrimSec ?? 0)
        let start = max(episode.playbackPosition, intro)
        let url = localURL(for: episode) ?? episode.audioURL
        engine.load(url: url, startAt: start)
        engine.rate = Float(settings?.speed ?? 1.0)
        positionSeconds = start
        engine.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying { engine.pause(); persistPosition() }
        else { engine.play() }
        isPlaying.toggle()
    }

    func skip(by seconds: TimeInterval) {
        let target = max(0, min(durationSeconds, positionSeconds + seconds))
        engine.seek(to: target); positionSeconds = target
    }

    func seek(toFraction f: Double) {
        let target = max(0, min(durationSeconds, durationSeconds * f))
        engine.seek(to: target); positionSeconds = target
    }

    // Resolve a downloaded file to a playable URL (Plan 5 populates downloadedFile).
    func localURL(for episode: Episode) -> URL? {
        guard let name = episode.downloadedFile?.localFileName else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func handleTimeUpdate(_ t: TimeInterval) {
        positionSeconds = t
        guard let ep = currentEpisode else { return }

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
