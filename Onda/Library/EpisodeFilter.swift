//  EpisodeFilter.swift
import Foundation

enum EpisodeFilter: String, CaseIterable, Sendable {
    case downloaded, all, newest10

    var label: String {
        switch self {
        case .downloaded: return "Downloaded"
        case .all: return "All"
        case .newest10: return "Newest 10"
        }
    }

    @MainActor
    func apply(to episodes: [Episode]) -> [Episode] {
        let sorted = episodes.filter { !$0.isArchived }
            .sorted { $0.publishDate > $1.publishDate }
        switch self {
        case .downloaded: return sorted.filter { $0.downloadedFile != nil }
        case .all: return sorted
        case .newest10: return Array(sorted.prefix(10))
        }
    }
}
