//  RecommendationService.swift
//  Orchestrates the retrieve → re-rank funnel, caches with a TTL, and exposes the "For You" list.
import Foundation
import SwiftData

/// Drives the on-device "For You" recommender: builds a taste profile from the user's own signals,
/// runs the retrieve → re-rank funnel, caches the result with a TTL, and exposes the ranked list.
/// Everything is computed on-device (no backend, no cross-user data). Wired app-wide as an
/// `@Observable` singleton; Discover reads ``recommendations``/``isLoading``/``isPersonalized``.
@MainActor
@Observable
final class RecommendationService {
    /// The current ranked recommendations (empty until the first refresh completes).
    var recommendations: [Recommendation] = []
    /// True while a refresh is in flight — lets the UI show a spinner without blocking the tab.
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

    /// True when the cached list is older than the TTL (or nothing has been computed yet).
    var isStale: Bool { lastComputed.map { now().timeIntervalSince($0) > Self.ttl } ?? true }

    /// Records a Discover search term into the taste-profile signal log (a bounded ring buffer).
    func recordSearch(_ term: String) { searchLog.record(term) }

    /// Recomputes recommendations only if the cache is stale and no refresh is already running —
    /// the cheap "on Discover appear" entry point.
    func refreshIfStale(followedCategories: [String]) async {
        guard isStale, !isLoading else { return }
        await refresh(followedCategories: followedCategories)
    }

    /// Rebuilds the taste profile and runs the full retrieve → re-rank funnel, replacing
    /// ``recommendations``. Mixes in top charts on a cold start / thin candidate pool.
    /// - Parameter followedCategories: categories of the user's subscriptions, used to steer
    ///   retrieval and the cold-start fallback.
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

    /// Marks a recommendation "not interested": adds it to the persistent dismissed set (so it
    /// won't return) and removes it from the current list.
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
