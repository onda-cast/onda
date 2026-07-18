//  SubscriptionService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class SubscriptionService {
    private let modelContext: ModelContext
    private let feeds: FeedFetching
    // Wired post-init in OndaApp (same style as PlaybackManager.onCaptureRequested) — the
    // retention sweep runs reactively on mark-played, and unsubscribe frees downloads.
    var retention: EpisodeRetentionService?
    var deleteDownload: ((Episode) -> Void)?
    var downloadEpisode: ((Episode) -> Void)?   // wired to DownloadManager.download in OndaApp

    init(modelContext: ModelContext, feeds: FeedFetching) {
        self.modelContext = modelContext
        self.feeds = feeds
    }

    @discardableResult
    func subscribe(to dto: PodcastDTO) async throws -> Podcast {
        guard let feedURL = dto.feedUrl else {
            throw NSError(domain: "Onda.Subscribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Show has no RSS feed URL"])
        }
        let podcast = try existingPodcast(feedURL: feedURL) ?? {
            let p = Podcast(feedURL: feedURL, title: dto.collectionName, author: dto.artistName,
                            artworkURL: dto.artworkUrl600, category: dto.primaryGenreName ?? "Podcast",
                            itunesId: dto.collectionId)
            modelContext.insert(p)
            return p
        }()
        try await activateSubscription(podcast)
        return podcast
    }

    /// Fetches and parses a feed without persisting anything — the AddFeedSheet preview step.
    func previewFeed(_ url: URL) async throws -> ParsedFeed {
        try await feeds.fetchFeed(url)
    }

    /// Subscribe to a feed directly by URL (private/paid tokenized feeds). Show metadata comes
    /// from the feed channel itself; nothing is persisted if the fetch fails.
    @discardableResult
    func subscribeToFeedURL(_ url: URL) async throws -> Podcast {
        let parsed = try await feeds.fetchFeed(url)   // validate before inserting anything
        let podcast = try existingPodcast(feedURL: url) ?? {
            let p = Podcast(feedURL: url, title: parsed.title, author: parsed.author,
                            artworkURL: parsed.artworkURL, category: parsed.category,
                            itunesId: nil, isPrivateFeed: true)
            modelContext.insert(p)
            return p
        }()
        try await activateSubscription(podcast)
        return podcast
    }

    /// Shared subscribe tail for both the iTunes and direct-URL paths: mark subscribed, ensure
    /// settings, pull episodes, and prime the newest episode for offline.
    private func activateSubscription(_ podcast: Podcast) async throws {
        podcast.isSubscribed = true
        if podcast.settings == nil {
            let s = ShowSettings.makeDefault(); s.podcast = podcast; podcast.settings = s
            modelContext.insert(s)
        }
        try await refreshEpisodes(for: podcast)
        try modelContext.save()
        // Grab the latest episode so a freshly-subscribed show has something ready offline.
        if let newest = podcast.episodes.max(by: { $0.publishDate < $1.publishDate }) {
            downloadEpisode?(newest)   // idempotent in DownloadManager
        }
    }

    func setPlayed(_ episode: Episode, _ played: Bool) {
        episode.played = played
        episode.playedDate = played ? .now : nil
        episode.playbackPosition = 0
        try? modelContext.save()
        // Reactive sweep so "auto-delete immediately" doesn't wait for the next feed refresh.
        if played, let podcast = episode.podcast {
            retention?.evictEligibleEpisodes(for: podcast)
        }
    }

    /// Marks every episode played in one pass, then runs the retention sweep ONCE — looping
    /// setPlayed would sweep per episode (O(n²) and could delete rows mid-iteration).
    func markAllPlayed(for podcast: Podcast) {
        for ep in podcast.episodes where !ep.played {
            ep.played = true
            ep.playedDate = .now
            ep.playbackPosition = 0
        }
        try? modelContext.save()
        retention?.evictEligibleEpisodes(for: podcast)
    }

    /// Soft delete. Audio/download removal is the caller's job (DownloadManager owns files);
    /// clips always survive; the transcript survives only when `keepTranscript`.
    func archiveEpisode(_ episode: Episode, keepTranscript: Bool) {
        episode.isArchived = true
        if !keepTranscript, let tr = episode.transcript {
            episode.transcript = nil
            modelContext.delete(tr)   // cascades cues
        }
        try? modelContext.save()
    }

    /// Unsubscribe IS the delete action for a show: downloaded audio is always freed, and
    /// transcripts are purged unless the resolved keep-transcripts setting says otherwise.
    func unsubscribe(_ podcast: Podcast) {
        podcast.isSubscribed = false
        let keepTranscripts = retention?.resolvedKeepTranscripts(for: podcast) ?? true
        for ep in podcast.episodes {
            if ep.downloadedFile != nil { deleteDownload?(ep) }
            if !keepTranscripts, let tr = ep.transcript {
                ep.transcript = nil
                modelContext.delete(tr)   // cascades cues
            }
        }
        try? modelContext.save()
    }

    func refreshEpisodes(for podcast: Podcast) async throws {
        let feed = try await feeds.fetchFeed(podcast.feedURL)
        let existing = Set(podcast.episodes.map(\.guid))
        // Build new episodes first and extend the relationship ONCE — per-item appends to a
        // SwiftData relationship array are quadratic (same class of hang as the cue persist).
        var added: [Episode] = []
        for pe in feed.episodes where !existing.contains(pe.guid) {
            let ep = Episode(guid: pe.guid, title: pe.title, publishDate: pe.publishDate,
                             duration: pe.duration, audioURL: pe.audioURL, notes: pe.notes,
                             chaptersURL: pe.chaptersURL,
                             transcriptURL: pe.transcriptURL, transcriptType: pe.transcriptType)
            modelContext.insert(ep)
            added.append(ep)
        }
        guard !added.isEmpty else { return }
        podcast.episodes.append(contentsOf: added)
        for ep in added { ep.podcast = podcast }
        try modelContext.save()
    }

    private func existingPodcast(feedURL: URL) throws -> Podcast? {
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        return try modelContext.fetch(d).first
    }
}
