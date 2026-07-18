//  ITunesSearchClientBox.swift
import Foundation

@MainActor
@Observable
final class ITunesSearchClientBox {
    let client: any Searching

    // Trending is cached here (not in DiscoverView's @State) so it survives the tab-switch
    // teardown/rebuild instead of re-fetching and flashing blank each visit.
    var trending: [PodcastDTO] = []
    var trendingLoading = false
    var trendingFailed = false
    private var loadedAt: Date?
    private static let ttl: TimeInterval = 30 * 60

    init(client: any Searching) { self.client = client }

    func loadTrendingIfNeeded(force: Bool = false) async {
        let fresh = loadedAt.map { Date().timeIntervalSince($0) < Self.ttl } ?? false
        guard force || (!fresh && !trendingLoading) else { return }
        trendingLoading = true; trendingFailed = false
        defer { trendingLoading = false }
        do {
            let ids = try await client.topChartIds(limit: 25)
            trending = try await client.lookup(ids: Array(ids.prefix(20)))
            loadedAt = .now
        } catch {
            trendingFailed = true
            if trending.isEmpty { loadedAt = nil }   // allow retry
        }
    }
}
