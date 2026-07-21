//  LibrarySort.swift
//  How the subscribed-shows list is ordered. Pure sorting so it's unit-testable; time-based
//  keys can't be expressed in a SwiftData @Query predicate, so sorting happens in-memory.
import Foundation

enum LibrarySort: String, CaseIterable {
    case alphabetical, newestEpisode, mostListened, recentlyPlayed

    var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .newestEpisode: "Newest Episode"
        case .mostListened: "Most Listened"
        case .recentlyPlayed: "Recently Played"
        }
    }

    var icon: String {
        switch self {
        case .alphabetical: "textformat.abc"
        case .newestEpisode: "sparkles"
        case .mostListened: "headphones"
        case .recentlyPlayed: "clock.arrow.circlepath"
        }
    }

    /// Sorts using precomputed `LibrarySortKeys` — the render path must NEVER touch
    /// `podcast.episodes` (each access faults the whole relationship; seconds on device).
    func sorted(_ shows: [Podcast], keys: LibrarySortKeys) -> [Podcast] {
        switch self {
        case .alphabetical:
            shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .newestEpisode:
            keySorted(shows) { keys.newestEpisode[$0.feedURL.absoluteString] }
        case .mostListened:
            keySorted(shows) { keys.playedCount[$0.feedURL.absoluteString].map(Double.init) }
        case .recentlyPlayed:
            keySorted(shows) { keys.lastPlayed[$0.feedURL.absoluteString] }
        }
    }

    /// Descending by `key`, falling back to title A→Z on ties; shows with no cached key
    /// (fresh subscribe before the background recompute lands) sort last.
    private func keySorted(_ shows: [Podcast], by key: (Podcast) -> Double?) -> [Podcast] {
        shows.map { (show: $0, key: key($0) ?? -.greatestFiniteMagnitude) }
            .sorted {
                if $0.key != $1.key { return $0.key > $1.key }
                return $0.show.title.localizedCaseInsensitiveCompare($1.show.title) == .orderedAscending
            }
            .map(\.show)
    }
}
