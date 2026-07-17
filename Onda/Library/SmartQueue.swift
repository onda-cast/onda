//  SmartQueue.swift
import Foundation

enum SmartQueue: String, CaseIterable, Sendable {
    case unplayed, downloaded, recentlyAdded, shortestFirst

    var label: String {
        switch self {
        case .unplayed: return "Unplayed"
        case .downloaded: return "Downloaded"
        case .recentlyAdded: return "Recently Added"
        case .shortestFirst: return "Shortest First"
        }
    }

    @MainActor
    func apply(to episodes: [Episode], now: Date = .now) -> [Episode] {
        let episodes = episodes.filter { !$0.isArchived }
        switch self {
        case .unplayed:
            return episodes.filter { !$0.played }
                .sorted { $0.publishDate > $1.publishDate }
        case .downloaded:
            return episodes.filter { !$0.played && $0.downloadedFile != nil }
                .sorted { $0.publishDate > $1.publishDate }
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            return episodes.filter { $0.publishDate >= cutoff && $0.publishDate <= now }
                .sorted { $0.publishDate > $1.publishDate }
        case .shortestFirst:
            return episodes.filter { !$0.played }
                .sorted { $0.duration < $1.duration }
        }
    }

    /// Cheap emptiness probe for chip disabled state: mirrors each case's predicate with a
    /// short-circuiting `contains(where:)` — no sorting, no intermediate arrays.
    /// Excludes archived episodes, same as `apply(to:now:)`.
    @MainActor
    func hasMatches(in episodes: [Episode], now: Date = .now) -> Bool {
        switch self {
        case .unplayed, .shortestFirst:
            return episodes.contains { !$0.isArchived && !$0.played }
        case .downloaded:
            return episodes.contains { !$0.isArchived && !$0.played && $0.downloadedFile != nil }
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            return episodes.contains { !$0.isArchived && $0.publishDate >= cutoff && $0.publishDate <= now }
        }
    }
}
