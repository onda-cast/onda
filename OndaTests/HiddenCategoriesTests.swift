//  HiddenCategoriesTests.swift
import XCTest
@testable import Onda

@MainActor
final class HiddenCategoriesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "HiddenCategoriesTests")
        defaults.removePersistentDomain(forName: "HiddenCategoriesTests")
    }

    private func dto(_ name: String, genre: String?) -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: name, artistName: "Artist",
                   feedUrl: URL(string: "https://ex.com/f.xml"), artworkUrl600: nil,
                   primaryGenreName: genre)
    }

    func test_all_isCanonicalAppleCategoryList() {
        XCTAssertEqual(HiddenCategories.all.count, 19)
        XCTAssertEqual(Set(HiddenCategories.all).count, 19, "no duplicates")
        XCTAssertTrue(HiddenCategories.all.contains("True Crime"))
        XCTAssertTrue(HiddenCategories.all.contains("Health & Fitness"))
    }

    func test_toggle_hidesAndUnhides_andPersistsAcrossInstances() {
        let store = HiddenCategories(defaults: defaults)
        XCTAssertFalse(store.isHidden(category: "True Crime"))

        store.toggle("True Crime")
        XCTAssertTrue(store.isHidden(category: "True Crime"))

        let reloaded = HiddenCategories(defaults: defaults)
        XCTAssertTrue(reloaded.isHidden(category: "True Crime"), "hidden set survives relaunch")

        store.toggle("True Crime")
        XCTAssertFalse(store.isHidden(category: "True Crime"))
    }

    func test_isHidden_dto_matchesOnPrimaryGenreName() {
        let store = HiddenCategories(defaults: defaults)
        let show = dto("Serial Killers Weekly", genre: "True Crime")
        let other = dto("Tech Talk", genre: "Technology")
        XCTAssertFalse(store.isHidden(show))

        store.toggle("True Crime")
        XCTAssertTrue(store.isHidden(show))
        XCTAssertFalse(store.isHidden(other))
    }

    func test_isHidden_dto_withNilGenre_isNeverHidden() {
        let store = HiddenCategories(defaults: defaults)
        store.toggle("True Crime")
        let noGenre = dto("Mystery Show", genre: nil)
        XCTAssertFalse(store.isHidden(noGenre))
    }
}
