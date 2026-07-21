//  SmartQueue.swift
import Foundation

enum SmartQueue: String, CaseIterable, Sendable {
    case unplayed, downloaded, recentlyAdded, shortestFirst

    var label: String {
        switch self {
        case .unplayed: "Unplayed"
        case .downloaded: "Downloaded"
        case .recentlyAdded: "Recently Added"
        case .shortestFirst: "Shortest First"
        }
    }

    /// The chips' candidate set, derived from the (small) DownloadedFile table. Scanning
    /// `shows.flatMap(\.episodes)` instead faults the `downloadedFile` relationship on EVERY
    /// library episode on the main thread — a multi-second Library tab switch on device.
    @MainActor
    static func downloadedCandidates(_ files: [DownloadedFile]) -> [Episode] {
        files.compactMap(\.episode).filter { $0.podcast?.isSubscribed == true }
    }

    @MainActor
    func apply(to episodes: [Episode], now: Date = .now) -> [Episode] {
        // Every chip is a lens onto downloaded episodes only — nothing here surfaces
        // an episode you can't play offline.
        let episodes = episodes.filter { !$0.isArchived && $0.downloadedFile != nil }
        switch self {
        case .unplayed:
            return episodes.filter { !$0.played }
                .sorted { $0.publishDate > $1.publishDate }
        case .downloaded:
            // ALL downloads, played included, most recently downloaded first.
            return episodes.sorted { ($0.downloadedFile?.downloadedAt ?? .distantPast) > ($1.downloadedFile?.downloadedAt ?? .distantPast) }
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
            return episodes.contains { !$0.isArchived && $0.downloadedFile != nil && !$0.played }
        case .downloaded:
            return episodes.contains { !$0.isArchived && $0.downloadedFile != nil }
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            return episodes.contains { !$0.isArchived && $0.downloadedFile != nil && $0.publishDate >= cutoff && $0.publishDate <= now }
        }
    }
}
