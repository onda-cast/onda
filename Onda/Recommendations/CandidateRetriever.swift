//  CandidateRetriever.swift
//  Stage 1 of the funnel: turn a taste profile into iTunes queries, gather a broad candidate pool,
//  and drop shows the user already has or has dismissed. iTunes is the only source of NEW shows.
import Foundation

@MainActor
struct CandidateRetriever {
    let client: Searching

    /// Query terms derived from the profile (pure, so it's unit-testable). Falls back to followed
    /// categories on a cold start (empty profile).
    static func queries(profile: TasteProfile, followedCategories: [String]) -> [String] {
        if profile.isEmpty {
            return Array(followedCategories.prefix(3))
        }
        var qs: [String] = []
        qs.append(contentsOf: profile.terms.topTerms(4))
        qs.append(contentsOf: profile.topCategories.prefix(2))
        qs.append(contentsOf: profile.topAuthors.prefix(2))
        // De-dupe case-insensitively, keep order.
        var seen = Set<String>()
        return qs.filter { seen.insert($0.lowercased()).inserted && !$0.isEmpty }
    }

    func retrieve(profile: TasteProfile, followedCategories: [String],
                  subscribedFeeds: Set<URL>, isDismissed: (PodcastDTO) -> Bool,
                  isCategoryHidden: (PodcastDTO) -> Bool = { _ in false },
                  limit: Int = 60) async -> [PodcastDTO] {
        let queries = Self.queries(profile: profile, followedCategories: followedCategories)
        // Search concurrently — sequential awaits made retrieval latency scale with query count.
        let tasks = queries.map { query in
            Task { @MainActor in try? await client.search(term: query) }
        }
        var merged: [PodcastDTO] = []
        for task in tasks {
            if let found = await task.value { merged.append(contentsOf: found) }
        }

        var seen = Set<String>()
        var pool: [PodcastDTO] = []
        for dto in merged {
            if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
            if isDismissed(dto) { continue }
            if isCategoryHidden(dto) { continue }
            let key = dto.feedUrl?.absoluteString
                ?? dto.collectionId.map(String.init) ?? dto.collectionName
            if seen.insert(key).inserted { pool.append(dto) }
            if pool.count >= limit { break }
        }
        return pool
    }
}
