//  DiscoverSuggestions.swift
import Foundation

/// Result of a "shake to discover" pass: the shows to show, the categories they were
/// drawn from (for the header subtitle), and whether the built-in fallback list was used.
struct ShakeSuggestions: Equatable {
    var picks: [PodcastDTO]
    var categories: [String]
    var usedFallback: Bool
}

/// Builds a random set of podcast suggestions for the shake gesture.
///
/// Draws up to two distinct categories from `followedCategories` (or `fallbackCategories`
/// when the user follows nothing), searches each, removes already-followed shows, de-dupes
/// and shuffles, then caps at `limit`. Randomness is injected via `rng` so the pipeline is
/// deterministic under test; a search that throws is skipped rather than fatal.
///
/// Callers must pass already-distinct category arrays.
func shakeSuggestions(
    followedCategories: [String],
    fallbackCategories: [String],
    subscribedFeeds: Set<URL>,
    limit: Int = 20,
    using client: any Searching,
    rng: inout some RandomNumberGenerator
) async -> ShakeSuggestions {
    let usedFallback = followedCategories.isEmpty
    let source = usedFallback ? fallbackCategories : followedCategories
    guard !source.isEmpty else {
        return ShakeSuggestions(picks: [], categories: [], usedFallback: usedFallback)
    }

    let chosen = Array(source.shuffled(using: &rng).prefix(2))

    var merged: [PodcastDTO] = []
    for category in chosen {
        if let found = try? await client.search(term: category) {
            merged.append(contentsOf: found)
        }
    }

    var seen = Set<String>()
    var deduped: [PodcastDTO] = []
    for dto in merged {
        if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
        let key = dto.feedUrl?.absoluteString
            ?? dto.collectionId.map(String.init)
            ?? dto.collectionName
        if seen.insert(key).inserted { deduped.append(dto) }
    }

    let picks = Array(deduped.shuffled(using: &rng).prefix(limit))
    return ShakeSuggestions(picks: picks, categories: chosen, usedFallback: usedFallback)
}
