//  ITunesSearchClientBox.swift
import Foundation

@MainActor
@Observable
final class ITunesSearchClientBox {
    let client: any Searching

    // Trending is cached here (not in DiscoverView's @State) so it survives the tab-switch
    // teardown/rebuild, AND persisted to UserDefaults so a cold launch shows today's charts
    // instantly without refetching. Charts move slowly — one fetch per calendar day is enough.
    var trending: [PodcastDTO] = []
    var trendingLoading = false
    var trendingFailed = false
    private var loadedAt: Date?
    private static let cacheKey = "trendingCache"
    private static let cacheDateKey = "trendingCacheDate"

    init(client: any Searching) {
        self.client = client
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([PodcastDTO].self, from: data),
           let date = UserDefaults.standard.object(forKey: Self.cacheDateKey) as? Date {
            trending = cached
            loadedAt = date
        }
    }

    func loadTrendingIfNeeded(force: Bool = false) async {
        // Fresh = fetched today (calendar day, not a rolling TTL).
        let fresh = !trending.isEmpty
            && loadedAt.map { Calendar.current.isDateInToday($0) } ?? false
        guard force || (!fresh && !trendingLoading) else { return }
        trendingLoading = true; trendingFailed = false
        defer { trendingLoading = false }
        do {
            let ids = try await client.topChartIds(limit: 25)
            trending = try await client.lookup(ids: Array(ids.prefix(20)))
            loadedAt = .now
            if let data = try? JSONEncoder().encode(trending) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
                UserDefaults.standard.set(loadedAt, forKey: Self.cacheDateKey)
            }
        } catch {
            trendingFailed = true
            if trending.isEmpty { loadedAt = nil }   // allow retry
        }
    }
}
