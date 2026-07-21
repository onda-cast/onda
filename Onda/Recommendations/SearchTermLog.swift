//  SearchTermLog.swift
//  Bounded ring buffer of recent Discover search terms (UserDefaults) — an interest signal for
//  the taste profile without a SwiftData model or migration.
import Foundation

@MainActor
final class SearchTermLog {
    private static let key = "recentSearchTerms"
    private static let maxTerms = 50
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var terms: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func record(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count >= 3 else { return }
        var current = terms.filter { $0 != cleaned }   // de-dupe, most-recent-wins
        current.append(cleaned)
        if current.count > Self.maxTerms { current.removeFirst(current.count - Self.maxTerms) }
        defaults.set(current, forKey: Self.key)
    }
}
