//  LibrarySortTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class LibrarySortTests: XCTestCase {
    private var ctx: ModelContext!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(c)
    }

    @discardableResult
    private func show(_ title: String, episodes: [(pub: Double, played: Double?)] = []) -> Podcast {
        let p = Podcast(feedURL: URL(string: "https://ex.com/\(title).xml")!, title: title, author: "A",
                        artworkURL: nil, category: "Tech", itunesId: 1)
        ctx.insert(p)
        for (i, e) in episodes.enumerated() {
            let ep = Episode(guid: "\(title)-\(i)", title: "E", publishDate: base.addingTimeInterval(e.pub),
                             duration: 100, audioURL: URL(string: "https://ex.com/\(title)\(i).mp3")!, notes: "")
            if let played = e.played { ep.played = true; ep.playedDate = base.addingTimeInterval(played) }
            ep.podcast = p; p.episodes.append(ep); ctx.insert(ep)
        }
        return p
    }

    func test_alphabetical_caseInsensitive() {
        let shows = [show("banana"), show("Apple"), show("cherry")]
        let keys = LibrarySortKeys.compute(podcasts: shows)
        XCTAssertEqual(LibrarySort.alphabetical.sorted(shows, keys: keys).map(\.title),
                       ["Apple", "banana", "cherry"])
    }

    func test_newestEpisode_mostRecentFirst_emptyLast() {
        let a = show("A", episodes: [(pub: 10, played: nil)])
        let b = show("B", episodes: [(pub: 100, played: nil)])
        let empty = show("Empty")
        let keys = LibrarySortKeys.compute(podcasts: [a, empty, b])
        XCTAssertEqual(LibrarySort.newestEpisode.sorted([a, empty, b], keys: keys).map(\.title),
                       ["B", "A", "Empty"])
    }

    func test_mostListened_byPlayedCount() {
        let a = show("A", episodes: [(0, 1), (0, 1)])          // 2 played
        let b = show("B", episodes: [(0, 1), (0, nil), (0, 1), (0, 1)]) // 3 played
        let c = show("C", episodes: [(0, nil)])                // 0 played
        XCTAssertEqual(LibrarySort.mostListened.sorted([a, c, b], keys: LibrarySortKeys.compute(podcasts: [a, c, b])).map(\.title), ["B", "A", "C"])
    }

    func test_recentlyPlayed_byLastPlayedDate_neverLast() {
        let a = show("A", episodes: [(0, 10)])
        let b = show("B", episodes: [(0, 500)])
        let never = show("Never", episodes: [(0, nil)])
        let keys = LibrarySortKeys.compute(podcasts: [a, never, b])
        XCTAssertEqual(LibrarySort.recentlyPlayed.sorted([a, never, b], keys: keys).map(\.title),
                       ["B", "A", "Never"])
    }

    func test_missingKeys_fallBackToTitleOrder() {
        // A show with no cached key (fresh subscribe before the background recompute lands)
        // sorts as "no data" — after keyed shows, alphabetical within the tie.
        let a = show("A", episodes: [(pub: 10, played: nil)])
        let fresh = show("Fresh", episodes: [(pub: 999, played: nil)])
        var keys = LibrarySortKeys.compute(podcasts: [a])   // fresh has NO entry
        _ = keys
        keys = LibrarySortKeys.compute(podcasts: [a])
        XCTAssertEqual(LibrarySort.newestEpisode.sorted([fresh, a], keys: keys).map(\.title),
                       ["A", "Fresh"])
    }

    func test_ties_fallBackToTitle() {
        let a = show("Zed", episodes: [(0, nil)])
        let b = show("Alpha", episodes: [(0, nil)])   // same newest-episode date
        XCTAssertEqual(LibrarySort.newestEpisode.sorted([a, b], keys: LibrarySortKeys.compute(podcasts: [a, b])).map(\.title), ["Alpha", "Zed"])
    }
}
