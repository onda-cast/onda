//  HiddenShowsTests.swift
import XCTest
@testable import Onda

@MainActor
final class HiddenShowsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "HiddenShowsTests")
        defaults.removePersistentDomain(forName: "HiddenShowsTests")
    }

    private func dto(_ name: String, feed: String? = "https://ex.com/f.xml") -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: name, artistName: "Artist",
                   feedUrl: feed.flatMap(URL.init(string:)), artworkUrl600: nil, primaryGenreName: nil)
    }

    func test_hide_isHidden_andPersistsAcrossInstances() {
        let store = HiddenShows(defaults: defaults)
        let show = dto("Hidden Show")
        XCTAssertFalse(store.isHidden(show))

        store.hide(show)
        XCTAssertTrue(store.isHidden(show))
        XCTAssertEqual(store.lastHidden?.title, "Hidden Show")

        let reloaded = HiddenShows(defaults: defaults)
        XCTAssertTrue(reloaded.isHidden(show), "hidden list survives relaunch")
        XCTAssertEqual(reloaded.shows.map(\.title), ["Hidden Show"])
    }

    func test_unhide_removes_andUndoRestoresVisibility() {
        let store = HiddenShows(defaults: defaults)
        let show = dto("Show")
        store.hide(show)
        store.undoHide()
        XCTAssertFalse(store.isHidden(show), "undo unhides")
        XCTAssertTrue(store.shows.isEmpty)

        store.hide(show)
        store.unhide(show.feedUrl!.absoluteString)
        XCTAssertFalse(store.isHidden(show))
    }

    func test_dtoWithoutFeed_cannotBeHidden() {
        let store = HiddenShows(defaults: defaults)
        let feedless = dto("No Feed", feed: nil)
        store.hide(feedless)
        XCTAssertFalse(store.isHidden(feedless))
        XCTAssertTrue(store.shows.isEmpty)
    }

    func test_hide_isIdempotent() {
        let store = HiddenShows(defaults: defaults)
        let show = dto("Show")
        store.hide(show)
        store.hide(show)
        XCTAssertEqual(store.shows.count, 1)
    }
}
