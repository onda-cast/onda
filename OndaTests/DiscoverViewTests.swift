//  DiscoverViewTests.swift
import XCTest
@testable import Onda

final class DiscoverViewTests: XCTestCase {
    private func dto(_ name: String, genre: String? = nil) -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: name, artistName: "Artist",
                   feedUrl: URL(string: "https://ex.com/f.xml"), artworkUrl600: nil,
                   primaryGenreName: genre)
    }

    func test_isVisible_categoryFilterOff_showsHiddenCategoryShow() {
        // Typed search / explicit category pick: filterCategories is false, so a hidden-category
        // show still shows — hiding a category never touches an explicit ask.
        let show = dto("Crime Show", genre: "True Crime")
        let visible = DiscoverView.isVisible(show, showHidden: { _ in false },
                                             categoryHidden: { $0.primaryGenreName == "True Crime" },
                                             filterCategories: false)
        XCTAssertTrue(visible)
    }

    func test_isVisible_categoryFilterOn_hidesHiddenCategoryShow() {
        // Trending / Shake: filterCategories is true, so a hidden-category show is dropped.
        let show = dto("Crime Show", genre: "True Crime")
        let visible = DiscoverView.isVisible(show, showHidden: { _ in false },
                                             categoryHidden: { $0.primaryGenreName == "True Crime" },
                                             filterCategories: true)
        XCTAssertFalse(visible)
    }

    func test_isVisible_categoryFilterOn_showsNonHiddenCategoryShow() {
        let show = dto("Tech Show", genre: "Technology")
        let visible = DiscoverView.isVisible(show, showHidden: { _ in false },
                                             categoryHidden: { $0.primaryGenreName == "True Crime" },
                                             filterCategories: true)
        XCTAssertTrue(visible)
    }

    func test_isVisible_hiddenShowIsAlwaysHidden_regardlessOfCategoryFilter() {
        let show = dto("Some Show", genre: "Technology")
        let visibleWhenFilterOff = DiscoverView.isVisible(show, showHidden: { _ in true },
                                                          categoryHidden: { _ in false },
                                                          filterCategories: false)
        let visibleWhenFilterOn = DiscoverView.isVisible(show, showHidden: { _ in true },
                                                         categoryHidden: { _ in false },
                                                         filterCategories: true)
        XCTAssertFalse(visibleWhenFilterOff)
        XCTAssertFalse(visibleWhenFilterOn)
    }
}
