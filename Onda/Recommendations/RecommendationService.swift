//  RecommendationService.swift
//  Orchestrates the retrieve → re-rank funnel, caches with a TTL, and exposes the "For You" list.
import Foundation
import SwiftData

@MainActor
@Observable
final class RecommendationService {
    var recommendations: [Recommendation] = []
    var isLoading = false
    /// False when the profile had no signal and the list is just top charts — lets the UI avoid
    /// over-promising ("Recommended for you" vs "Popular right now").
    private(set) var isPersonalized = false
    private var lastComputed: Date?
    static let ttl: TimeInterval = 6 * 3600

    private let modelContext: ModelContext
    private let client: Searching
    private let retriever: CandidateRetriever
    private let reranker: CandidateReranker
    private let searchLog: SearchTermLog
    private let dismissedStore: DismissedShows
    private let now: () -> Date

    init(modelContext: ModelContext, client: Searching, feeds: FeedFetching,
         embedding: WordEmbedding? = AppleWordEmbedding(),
         searchLog: SearchTermLog? = nil, dismissed: DismissedShows? = nil,
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.client = client
        self.retriever = CandidateRetriever(client: client)
        self.reranker = CandidateReranker(feeds: feeds, embedding: embedding)
        self.searchLog = searchLog ?? SearchTermLog()
        self.dismissedStore = dismissed ?? DismissedShows()
        self.now = now
    }

    var isStale: Bool { lastComputed.map { now().timeIntervalSince($0) > Self.ttl } ?? true }

    func recordSearch(_ term: String) { searchLog.record(term) }

    func refreshIfStale(followedCategories: [String]) async {
        guard isStale, !isLoading else { return }
        await refresh(followedCategories: followedCategories)
    }

    func refresh(followedCategories: [String]) async {
        isLoading = true
        defer { isLoading = false }

        let subs = (try? modelContext.fetch(
            FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed }))) ?? []
        let clips = (try? modelContext.fetch(FetchDescriptor<Clip>())) ?? []
        let profile = TasteProfileBuilder.build(subscriptions: subs, clips: clips,
                                                searchTerms: searchLog.terms)
        isPersonalized = !profile.isEmpty
        let subscribedFeeds = Set(subs.map(\.feedURL))

        var pool = await retriever.retrieve(
            profile: profile, followedCategories: followedCategories,
            subscribedFeeds: subscribedFeeds, isDismissed: { [dismissedStore] in dismissedStore.contains($0) })

        // Cold start / thin pool: mix in the top charts so there's always something to show.
        if pool.count < 10 {
            pool.append(contentsOf: await charts(excluding: subscribedFeeds, existing: pool))
        }

        recommendations = await reranker.rank(profile: profile, candidates: pool)
        lastComputed = now()
    }

    func dismiss(_ rec: Recommendation) {
        dismissedStore.dismiss(rec.dto)
        recommendations.removeAll { $0.id == rec.id }
    }

    private func charts(excluding subscribedFeeds: Set<URL>, existing: [PodcastDTO]) async -> [PodcastDTO] {
        guard let ids = try? await client.topChartIds(limit: 25),
              let charts = try? await client.lookup(ids: Array(ids.prefix(20))) else { return [] }
        let have = Set(existing.compactMap { $0.feedUrl?.absoluteString })
        return charts.filter { dto in
            guard let feed = dto.feedUrl else { return false }
            return !subscribedFeeds.contains(feed) && !have.contains(feed.absoluteString)
                && !dismissedStore.contains(dto)
        }
    }
}
