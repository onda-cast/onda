//  EpisodeRetentionService.swift
//  Download/retention rules: global defaults (AppSettings) resolved against per-show overrides
//  (ShowSettings), applied by a sweep that is deliberately conservative — the count cap and the
//  listened-age rule only ever touch PLAYED downloaded episodes; unplayed downloads are never
//  auto-deleted, even when that leaves a show over its cap.
import Foundation
import SwiftData

/// Resolves the app's download/retention rules — global defaults (``AppSettings``) overridden
/// per-show (`ShowSettings`) — and applies them with a deliberately conservative sweep: the count
/// cap and the listened-age rule only ever touch **played** downloaded episodes, so an unplayed
/// download is never auto-deleted. Wired app-wide as an `@Observable` singleton; the sweep runs
/// reactively on mark-played and periodically from `FeedRefreshService`.
@MainActor
@Observable
final class EpisodeRetentionService {
    private let modelContext: ModelContext
    private let appSettings: AppSettings
    private let deleteDownload: (Episode) -> Void   // DownloadManager.delete in the app
    private let now: () -> Date                     // injectable clock for the day-based rule
    // Wired to PlaybackManager in OndaApp. Without this, marking the currently-playing episode
    // played (swipe, "mark all played") could evict the file backing the live AVPlayerItem —
    // guarded by guid, not object identity, matching how the rest of the app compares episodes.
    private let isCurrentlyPlaying: (Episode) -> Bool

    init(modelContext: ModelContext, appSettings: AppSettings,
         deleteDownload: @escaping (Episode) -> Void,
         isCurrentlyPlaying: @escaping (Episode) -> Bool = { _ in false },
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.deleteDownload = deleteDownload
        self.isCurrentlyPlaying = isCurrentlyPlaying
        self.now = now
    }

    // MARK: Resolution — override ?? global default

    /// Per-show cap on total downloaded episodes, override falling back to the global default.
    /// `0` means no limit.
    func resolvedMaxDownloadsKept(for podcast: Podcast) -> Int {
        podcast.settings?.maxDownloadsKeptOverride ?? appSettings.defaultMaxDownloadsKept
    }

    /// Days after which a *listened* episode is auto-deleted, override falling back to the global
    /// default. `-1` means off; `0` means immediately on being marked played.
    func resolvedAutoDeleteAfterDays(for podcast: Podcast) -> Int {
        podcast.settings?.autoDeleteListenedAfterDaysOverride
            ?? appSettings.defaultAutoDeleteListenedAfterDays
    }

    /// Whether to auto-start on-device transcription when a download finishes, override falling
    /// back to the global default.
    func resolvedAutoTranscribe(for podcast: Podcast) -> Bool {
        podcast.settings?.autoTranscribeOnDownloadOverride
            ?? appSettings.defaultAutoTranscribeOnDownload
    }

    /// Whether an episode's transcript survives when its audio is deleted/unsubscribed, override
    /// falling back to the global default.
    func resolvedKeepTranscripts(for podcast: Podcast) -> Bool {
        podcast.settings?.keepTranscriptsOverride ?? appSettings.keepTranscriptsOnDelete
    }

    // MARK: Sweep

    /// Applies both retention rules to one show — delete listened-past-age episodes, then free the
    /// oldest played downloads beyond the cap — and saves. Safe to call often; it's a no-op when
    /// nothing is eligible.
    func evictEligibleEpisodes(for podcast: Podcast) {
        evictListenedPastAge(for: podcast)
        evictBeyondDownloadCap(for: podcast)
        try? modelContext.save()
    }

    /// Rule 1: listened episodes whose playedDate is older than the resolved threshold are
    /// fully deleted — audio freed AND archived, exactly like a manual swipe-delete.
    ///
    /// Article episodes (`sourceType == "article"`) are excluded: their `audioURL` IS the local
    /// TTS-generated `.m4a` — there is no remote feed to re-download from, so evicting them would
    /// be permanent, silent data loss rather than a reclaimable cache eviction.
    private func evictListenedPastAge(for podcast: Podcast) {
        let days = resolvedAutoDeleteAfterDays(for: podcast)
        guard days >= 0 else { return }
        let cutoff = now().addingTimeInterval(-Double(days) * 86400)
        let keep = resolvedKeepTranscripts(for: podcast)
        for ep in podcast.episodes where ep.played && !ep.isArchived && ep.sourceType != "article" {
            guard let playedAt = ep.playedDate, playedAt <= cutoff, !isCurrentlyPlaying(ep) else { continue }
            if ep.downloadedFile != nil { deleteDownload(ep) }
            archive(ep, keepTranscript: keep)
        }
    }

    /// Rule 2: beyond the per-show download cap, the oldest PLAYED downloads lose their audio.
    /// Only the file is freed — the episode is not archived, so it stays listed/streamable.
    ///
    /// Article episodes are excluded from the eviction candidate pool for the same reason as
    /// Rule 1 above: their audio is local-only with no re-download source, so freeing it would
    /// strand the episode unplayable forever instead of just evicting a reclaimable cache entry.
    private func evictBeyondDownloadCap(for podcast: Podcast) {
        let cap = resolvedMaxDownloadsKept(for: podcast)
        guard cap > 0 else { return }
        let downloaded = podcast.episodes.filter { $0.downloadedFile != nil && !$0.isArchived }
        let overflow = downloaded.count - cap
        guard overflow > 0 else { return }
        let evictable = downloaded.filter { $0.played && $0.sourceType != "article" && !isCurrentlyPlaying($0) }
            .sorted { $0.publishDate < $1.publishDate }
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
