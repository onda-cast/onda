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
    // Same store DiscoverView/HiddenPodcastsView write to (share the app-wide instance passed
    // in — see hidden note below) — hidden shows were previously only stripped at render time,
    // so they still consumed retrieval/rerank budget (network fetch + embedding scoring) and
    // silently shrank the visible list below its intended size.
    private let hiddenStore: HiddenShows
    private let hiddenCategoriesStore: HiddenCategories
    private let now: () -> Date

    init(modelContext: ModelContext, client: Searching, feeds: FeedFetching,
         embedding: WordEmbedding? = AppleWordEmbedding(),
         searchLog: SearchTermLog? = nil, dismissed: DismissedShows? = nil,
         hidden: HiddenShows? = nil,
         hiddenCategories: HiddenCategories? = nil,
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.client = client
        self.retriever = CandidateRetriever(client: client)
        self.reranker = CandidateReranker(feeds: feeds, embedding: embedding)
        self.searchLog = searchLog ?? SearchTermLog()
        self.dismissedStore = dismissed ?? DismissedShows()
        self.hiddenStore = hidden ?? HiddenShows()
        self.hiddenCategoriesStore = hiddenCategories ?? HiddenCategories()
        self.now = now
    }

    /// True when the cached list is older than the TTL (or nothing has been computed yet).
    var isStale: Bool {
        lastComputed.map { now().timeIntervalSince($0) > Self.ttl } ?? true
    }

    /// Records a Discover search term into the taste-profile signal log (a bounded ring buffer).
    func recordSearch(_ term: String) {
        searchLog.record(term)
    }

    /// Recomputes recommendations only if the cache is stale and no refresh is already running —
    /// the cheap "on Discover appear" entry point.
    func refreshIfStale(followedCategories: [String]) async {
        guard isStale, !isLoading else { return }
        await refresh(followedCategories: followedCategories)
    }

    /// "Show me different shows": rebuilds the list excluding everything currently displayed
    /// (session-only — unlike dismiss, the exclusion isn't persisted, so those shows can come
    /// back in a future refresh).
    func refreshShowingDifferent(followedCategories: [String]) async {
        let shown = Set(recommendations.compactMap(\.dto.feedUrl))
        await refresh(followedCategories: followedCategories, excluding: shown)
    }

    /// Rebuilds the taste profile and runs the full retrieve → re-rank funnel, replacing
    /// ``recommendations``. Mixes in top charts on a cold start / thin candidate pool.
    /// - Parameters:
    ///   - followedCategories: categories of the user's subscriptions, used to steer retrieval
    ///     and the cold-start fallback.
    ///   - excluding: feed URLs to leave out of this rebuild (on top of subscribed + dismissed).
    func refresh(followedCategories: [String], excluding: Set<URL> = []) async {
        isLoading = true
        lastDismissed = nil
        defer { isLoading = false }

        // Cheap: only feedURL is read here, no episode/transcript faulting.
        let subs = (try? modelContext.fetch(
            FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed })
        )) ?? []
        let subscribedFeeds = Set(subs.map(\.feedURL))

        // The taste profile is the expensive part — it faults every subscribed show's episodes
        // AND their transcript cues. Re-fetch and build it in a background ModelContext (same
        // stale-while-revalidate-free pattern as StorageBreakdown/LibrarySortKeys) instead of
        // doing that on the main actor, which could visibly hitch Discover.
        let searchTerms = searchLog.terms
        let container = modelContext.container
        let profile = await Task.detached(priority: .userInitiated) {
            let bg = ModelContext(container)
            let subs = (try? bg.fetch(
                FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed })
            )) ?? []
            let clips = (try? bg.fetch(FetchDescriptor<Clip>())) ?? []
            return TasteProfileBuilder.build(subscriptions: subs, clips: clips, searchTerms: searchTerms)
        }.value
        isPersonalized = !profile.isEmpty

        var pool = await retriever.retrieve(
            profile: profile, followedCategories: followedCategories,
            subscribedFeeds: subscribedFeeds,
            isDismissed: { [dismissedStore, hiddenStore] dto in
                dismissedStore.contains(dto) || hiddenStore.isHidden(dto)
                    || dto.feedUrl.map(excluding.contains) ?? false
            },
            isCategoryHidden: { [hiddenCategoriesStore] dto in hiddenCategoriesStore.isHidden(dto) }
        )

        // Cold start / thin pool: mix in the top charts so there's always something to show.
        if pool.count < 10 {
            await pool.append(contentsOf: charts(excluding: subscribedFeeds.union(excluding),
                                                 existing: pool))
        }

        recommendations = await reranker.rank(profile: profile, candidates: pool)
        lastComputed = now()
    }

    /// The most recent dismissal, kept so the UI can offer Undo. Cleared by the next refresh,
    /// the next dismissal (replaced), or a successful undo.
    private(set) var lastDismissed: Recommendation?
    private var lastDismissedIndex: Int = 0

    /// Marks a recommendation "not interested": adds it to the persistent dismissed set (so it
    /// won't return) and removes it from the current list. Reversible via ``undoDismiss()``.
    func dismiss(_ rec: Recommendation) {
        lastDismissedIndex = recommendations.firstIndex { $0.id == rec.id } ?? 0
        lastDismissed = rec
        dismissedStore.dismiss(rec.dto)
        recommendations.removeAll { $0.id == rec.id }
    }

    /// Reverses the most recent ``dismiss(_:)``: un-persists it and restores the row in place.
    func undoDismiss() {
        guard let rec = lastDismissed else { return }
        dismissedStore.undismiss(rec.dto)
        recommendations.insert(rec, at: min(lastDismissedIndex, recommendations.count))
        lastDismissed = nil
    }

    private func charts(excluding subscribedFeeds: Set<URL>, existing: [PodcastDTO]) async -> [PodcastDTO] {
        guard let ids = try? await client.topChartIds(limit: 25),
              let charts = try? await client.lookup(ids: Array(ids.prefix(20))) else { return [] }
        let have = Set(existing.compactMap { $0.feedUrl?.absoluteString })
        return charts.filter { dto in
            guard let feed = dto.feedUrl else { return false }
            return !subscribedFeeds.contains(feed) && !have.contains(feed.absoluteString)
                && !dismissedStore.contains(dto) && !hiddenStore.isHidden(dto)
                && !hiddenCategoriesStore.isHidden(dto)
        }
    }
}
