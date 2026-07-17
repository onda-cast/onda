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
}
