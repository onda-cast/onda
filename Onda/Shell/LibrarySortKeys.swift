//  LibrarySortKeys.swift
//  Precomputed per-show sort keys for the Library. Computing them inline faulted every
//  episode of every show through SwiftData on the main thread (~325ms per body evaluation
//  at 3k episodes in the sim, seconds on device) — the "big delay switching to Library".
//  Same stale-while-revalidate shape as StorageCalculator: the cached snapshot sorts
//  instantly; a background ModelContext recomputes on each Library appearance.
import Foundation
import SwiftData

struct LibrarySortKeys: Equatable, Sendable, Codable {
    // Keyed by Podcast.feedURL.absoluteString. Absent key = "no data" (sorts last).
    var newestEpisode: [String: Double] = [:]
    var lastPlayed: [String: Double] = [:]
    var playedCount: [String: Int] = [:]
    // The Library grid's "new episodes" badge count — unplayed, downloaded, non-archived
    // episodes (what's actually ready to listen to offline right now). Piggybacks on this
    // same background pass (which already walks every show's episodes for the fields above)
    // instead of a second full episode scan just for this.
    var unplayedCount: [String: Int] = [:]

    /// Scans every show's episodes — call on a background context (or in tests).
    static func compute(podcasts: [Podcast]) -> LibrarySortKeys {
        var keys = LibrarySortKeys()
        for pod in podcasts {
            let id = pod.feedURL.absoluteString
            var newest = -Double.greatestFiniteMagnitude
            var played = -Double.greatestFiniteMagnitude
            var count = 0
            var unplayed = 0
            for ep in pod.episodes {
                newest = max(newest, ep.publishDate.timeIntervalSince1970)
                if let d = ep.playedDate { played = max(played, d.timeIntervalSince1970) }
                if ep.played {
                    count += 1
                } else if !ep.isArchived && ep.downloadedFile != nil {
                    unplayed += 1
                }
            }
            keys.newestEpisode[id] = newest
            keys.lastPlayed[id] = played
            keys.playedCount[id] = count
            keys.unplayedCount[id] = unplayed
        }
        return keys
    }

    static func computeInBackground(container: ModelContainer,
                                    defaults: UserDefaults = .standard) async -> LibrarySortKeys {
        let fresh = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let pods = (try? context.fetch(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.isSubscribed }
            ))) ?? []
            return compute(podcasts: pods)
        }.value
        save(fresh, defaults: defaults)
        return fresh
    }

    static let cacheKey = "librarySortKeysCache"

    static func cached(defaults: UserDefaults = .standard) -> LibrarySortKeys? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(LibrarySortKeys.self, from: data)
    }

    static func save(_ keys: LibrarySortKeys, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(keys) {
            defaults.set(data, forKey: cacheKey)
        }
    }
}
