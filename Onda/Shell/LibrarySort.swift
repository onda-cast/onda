//  LibrarySort.swift
//  How the subscribed-shows list is ordered. Pure sorting so it's unit-testable; time-based
//  keys can't be expressed in a SwiftData @Query predicate, so sorting happens in-memory.
import Foundation

enum LibrarySort: String, CaseIterable {
    case alphabetical, newestEpisode, mostListened, recentlyPlayed

    var label: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .newestEpisode: return "Newest Episode"
        case .mostListened: return "Most Listened"
        case .recentlyPlayed: return "Recently Played"
        }
    }
    var icon: String {
        switch self {
        case .alphabetical: return "textformat.abc"
        case .newestEpisode: return "sparkles"
        case .mostListened: return "headphones"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        }
    }

    func sorted(_ shows: [Podcast]) -> [Podcast] {
        switch self {
        case .alphabetical:
            return shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .newestEpisode:
            return shows.sorted { keyed($0, Self.newestEpisodeDate, tieBreak: $1) }
        case .mostListened:
            return shows.sorted { keyed($0, { Double(Self.playedCount($0)) }, tieBreak: $1) }
        case .recentlyPlayed:
            return shows.sorted { keyed($0, Self.lastPlayedDate, tieBreak: $1) }
        }
    }

    /// Descending by `key`, falling back to title A→Z on ties (and for equal/absent keys).
    private func keyed(_ a: Podcast, _ key: (Podcast) -> Double, tieBreak b: Podcast) -> Bool {
        let ka = key(a), kb = key(b)
        if ka != kb { return ka > kb }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    private static func newestEpisodeDate(_ p: Podcast) -> Double {
        p.episodes.map(\.publishDate).max().map(\.timeIntervalSince1970) ?? -.greatestFiniteMagnitude
    }
    private static func lastPlayedDate(_ p: Podcast) -> Double {
        p.episodes.compactMap(\.playedDate).max().map(\.timeIntervalSince1970) ?? -.greatestFiniteMagnitude
    }
    private static func playedCount(_ p: Podcast) -> Int {
        p.episodes.filter(\.played).count
    }
}
