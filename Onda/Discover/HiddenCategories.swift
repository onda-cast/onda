//  HiddenCategories.swift
//  User-curated "never suggest this genre" list: hidden categories are filtered out of
//  Trending, category browsing, Shake, and For You recommendations. Search results are never
//  filtered — an explicit search is an explicit ask. Managed entirely from the Hidden
//  Categories settings screen (no swipe/context entry point elsewhere, unlike HiddenShows).
import Foundation

@MainActor
@Observable
final class HiddenCategories {
    static let key = "hiddenCategoriesList"

    /// Apple's top-level podcast categories — the picker's full list, so a category can be
    /// hidden pre-emptively even before it's ever shown up in the user's results.
    static let all = [
        "Arts", "Business", "Comedy", "Education", "Fiction", "Government", "Health & Fitness",
        "History", "Kids & Family", "Leisure", "Music", "News", "Religion & Spirituality",
        "Science", "Society & Culture", "Sports", "Technology", "True Crime", "TV & Film"
    ]

    private let defaults: UserDefaults
    private(set) var hidden: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isHidden(category: String) -> Bool {
        hidden.contains(category)
    }

    func isHidden(_ dto: PodcastDTO) -> Bool {
        dto.primaryGenreName.map(isHidden(category:)) ?? false
    }

    func toggle(_ category: String) {
        if hidden.contains(category) { hidden.remove(category) } else { hidden.insert(category) }
        persist()
    }

    private func persist() {
        defaults.set(Array(hidden), forKey: Self.key)
    }
}
