//  SubscriptionService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class SubscriptionService {
    private let modelContext: ModelContext
    private let feeds: FeedFetching

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
        podcast.isSubscribed = true
        if podcast.settings == nil {
            let s = ShowSettings.makeDefault(); s.podcast = podcast; podcast.settings = s
            modelContext.insert(s)
        }
        try await refreshEpisodes(for: podcast)
        try modelContext.save()
        return podcast
    }

    func unsubscribe(_ podcast: Podcast) {
        podcast.isSubscribed = false
        try? modelContext.save()
    }

    func refreshEpisodes(for podcast: Podcast) async throws {
        let feed = try await feeds.fetchFeed(podcast.feedURL)
        let existing = Set(podcast.episodes.map(\.guid))
        for pe in feed.episodes where !existing.contains(pe.guid) {
            let ep = Episode(guid: pe.guid, title: pe.title, publishDate: pe.publishDate,
                             duration: pe.duration, audioURL: pe.audioURL, notes: pe.notes,
                             chaptersURL: pe.chaptersURL,
                             transcriptURL: pe.transcriptURL, transcriptType: pe.transcriptType)
            ep.podcast = podcast
            podcast.episodes.append(ep)
            modelContext.insert(ep)
        }
        try modelContext.save()
    }

    private func existingPodcast(feedURL: URL) throws -> Podcast? {
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        return try modelContext.fetch(d).first
    }
}
