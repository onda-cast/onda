//  HiddenShows.swift
//  User-curated "never show me this" list for Discover: hidden shows are filtered out of
//  search results, trending, and recommendations, and managed (unhidden) from Settings.
//  Distinct from DismissedShows, the recommendations-only "not interested" taste signal.
import Foundation

struct HiddenShow: Codable, Equatable, Identifiable {
    let feed: String          // feedURL absoluteString — the identity every surface shares
    let title: String
    let author: String?
    var id: String {
        feed
    }
}

@MainActor
@Observable
final class HiddenShows {
    static let key = "hiddenShowsList"
    private let defaults: UserDefaults
    private(set) var shows: [HiddenShow]
    /// The most recent hide, for the Discover undo toast.
    private(set) var lastHidden: HiddenShow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([HiddenShow].self, from: data) {
            shows = decoded
        } else {
            shows = []
        }
    }

    func hide(_ dto: PodcastDTO) {
        guard let feed = dto.feedUrl?.absoluteString else { return }   // no identity → can't hide
        guard !shows.contains(where: { $0.feed == feed }) else { return }
        let entry = HiddenShow(feed: feed, title: dto.collectionName, author: dto.artistName)
        shows.append(entry)
        lastHidden = entry
        persist()
    }

    func unhide(_ feed: String) {
        shows.removeAll { $0.feed == feed }
        if lastHidden?.feed == feed { lastHidden = nil }
        persist()
    }

    func undoHide() {
        guard let last = lastHidden else { return }
        unhide(last.feed)
    }

    func isHidden(_ dto: PodcastDTO) -> Bool {
        guard let feed = dto.feedUrl?.absoluteString else { return false }
        return shows.contains { $0.feed == feed }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shows) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
