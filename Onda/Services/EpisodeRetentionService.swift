//  EpisodeRetentionService.swift
//  Download/retention rules: global defaults (AppSettings) resolved against per-show overrides
//  (ShowSettings), applied by a sweep that is deliberately conservative — the count cap and the
//  listened-age rule only ever touch PLAYED downloaded episodes; unplayed downloads are never
//  auto-deleted, even when that leaves a show over its cap.
import Foundation
import SwiftData

@MainActor
@Observable
final class EpisodeRetentionService {
    private let modelContext: ModelContext
    private let appSettings: AppSettings
    private let deleteDownload: (Episode) -> Void   // DownloadManager.delete in the app
    private let now: () -> Date                     // injectable clock for the day-based rule

    init(modelContext: ModelContext, appSettings: AppSettings,
         deleteDownload: @escaping (Episode) -> Void,
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.deleteDownload = deleteDownload
        self.now = now
    }

    // MARK: Resolution — override ?? global default

    /// 0 = no limit.
    func resolvedMaxDownloadsKept(for podcast: Podcast) -> Int {
        podcast.settings?.maxDownloadsKeptOverride ?? appSettings.defaultMaxDownloadsKept
    }

    /// -1 = off, 0 = immediately.
    func resolvedAutoDeleteAfterDays(for podcast: Podcast) -> Int {
        podcast.settings?.autoDeleteListenedAfterDaysOverride
            ?? appSettings.defaultAutoDeleteListenedAfterDays
    }

    func resolvedAutoTranscribe(for podcast: Podcast) -> Bool {
        podcast.settings?.autoTranscribeOnDownloadOverride
            ?? appSettings.defaultAutoTranscribeOnDownload
    }

    func resolvedKeepTranscripts(for podcast: Podcast) -> Bool {
        podcast.settings?.keepTranscriptsOverride ?? appSettings.keepTranscriptsOnDelete
    }

    // MARK: Sweep

    func evictEligibleEpisodes(for podcast: Podcast) {
        evictListenedPastAge(for: podcast)
        evictBeyondDownloadCap(for: podcast)
        try? modelContext.save()
    }

    /// Rule 1: listened episodes whose playedDate is older than the resolved threshold are
    /// fully deleted — audio freed AND archived, exactly like a manual swipe-delete.
    private func evictListenedPastAge(for podcast: Podcast) {
        let days = resolvedAutoDeleteAfterDays(for: podcast)
        guard days >= 0 else { return }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let keep = resolvedKeepTranscripts(for: podcast)
        for ep in podcast.episodes where ep.played && !ep.isArchived {
            guard let playedAt = ep.playedDate, playedAt <= cutoff else { continue }
            if ep.downloadedFile != nil { deleteDownload(ep) }
            archive(ep, keepTranscript: keep)
        }
    }

    /// Rule 2: beyond the per-show download cap, the oldest PLAYED downloads lose their audio.
    /// Only the file is freed — the episode is not archived, so it stays listed/streamable.
    private func evictBeyondDownloadCap(for podcast: Podcast) {
        let cap = resolvedMaxDownloadsKept(for: podcast)
        guard cap > 0 else { return }
        let downloaded = podcast.episodes.filter { $0.downloadedFile != nil && !$0.isArchived }
        let overflow = downloaded.count - cap
        guard overflow > 0 else { return }
        let evictable = downloaded.filter(\.played).sorted { $0.publishDate < $1.publishDate }
        for ep in evictable.prefix(overflow) {
            deleteDownload(ep)
        }
    }

    /// Same semantics as SubscriptionService.archiveEpisode, inlined so the sweep has no
    /// dependency cycle with SubscriptionService.
    private func archive(_ episode: Episode, keepTranscript: Bool) {
        episode.isArchived = true
        if !keepTranscript, let tr = episode.transcript {
            episode.transcript = nil
            modelContext.delete(tr)   // cascades cues
        }
    }
}
