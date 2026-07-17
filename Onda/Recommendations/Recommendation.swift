//  Recommendation.swift
import Foundation

struct Recommendation: Identifiable, Equatable {
    let dto: PodcastDTO
    let score: Double
    let reasons: [String]

    var id: String { dto.feedUrl?.absoluteString ?? dto.collectionId.map(String.init) ?? dto.collectionName }
    /// Single-line "why" shown under the card.
    var reasonLine: String? { reasons.first }
}

@MainActor
final class DismissedShows {
    private static let key = "dismissedRecommendationFeeds"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private(set) var feeds: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.key) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.key) }
    }

    func dismiss(_ dto: PodcastDTO) {
        guard let feed = dto.feedUrl?.absoluteString else { return }
        feeds.insert(feed)
    }

    func contains(_ dto: PodcastDTO) -> Bool {
        guard let feed = dto.feedUrl?.absoluteString else { return false }
        return feeds.contains(feed)
    }
}
