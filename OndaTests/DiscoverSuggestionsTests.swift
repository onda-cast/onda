//  DiscoverSuggestionsTests.swift
import XCTest
@testable import Onda

// Deterministic RNG (SplitMix64) so shuffles/picks are reproducible in tests.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct StubSearch: Searching {
    var byTerm: [String: [PodcastDTO]] = [:]
    var throwingTerms: Set<String> = []
    enum StubError: Error { case boom }
    func search(term: String) async throws -> [PodcastDTO] {
        if throwingTerms.contains(term) { throw StubError.boom }
        return byTerm[term] ?? []
    }
    func lookup(ids: [Int]) async throws -> [PodcastDTO] { [] }
    func topChartIds(limit: Int) async throws -> [Int] { [] }
}

private func dto(_ name: String, feed: String?, id: Int? = nil) -> PodcastDTO {
    PodcastDTO(collectionId: id, collectionName: name, artistName: "Artist",
               feedUrl: feed.flatMap { URL(string: $0) }, artworkUrl600: nil,
               primaryGenreName: nil)
}

@MainActor
final class DiscoverSuggestionsTests: XCTestCase {

    func test_usesFollowedCategories_whenPresent() async {
        let client = StubSearch(byTerm: [
            "Technology": [dto("Tech Show", feed: "https://ex.com/tech.xml")],
            "Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.categories, ["Technology"])
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Tech Show"])
    }

    func test_fallsBackToBuiltInCategories_whenNoFollows() async {
        let client = StubSearch(byTerm: [
            "Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: [], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.categories, ["Comedy"])
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Funny Show"])
    }

    func test_filtersAlreadyFollowedShows() async {
        let followedFeed = "https://ex.com/tech-a.xml"
        let client = StubSearch(byTerm: [
            "Technology": [dto("Tech A", feed: followedFeed),
                           dto("Tech B", feed: "https://ex.com/tech-b.xml")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [URL(string: followedFeed)!], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Tech B"])
    }

    func test_dedupesAcrossCategories() async {
        let shared = dto("Shared Show", feed: "https://ex.com/shared.xml")
        let client = StubSearch(byTerm: [
            "Technology": [shared],
            "Comedy": [shared, dto("Comedy Only", feed: "https://ex.com/co.xml")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology", "Comedy"], fallbackCategories: ["News"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertEqual(result.picks.count, 2)
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Shared Show", "Comedy Only"])
    }

    func test_capsResultsAtLimit() async {
        let many = (0..<30).map { dto("Show \($0)", feed: "https://ex.com/\($0).xml") }
        let client = StubSearch(byTerm: ["Technology": many])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], limit: 20, using: client, rng: &rng)

        XCTAssertEqual(result.picks.count, 20)
    }

    func test_skipsThrowingCategory() async {
        let client = StubSearch(
            byTerm: ["Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")]],
            throwingTerms: ["Technology"])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology", "Comedy"], fallbackCategories: ["News"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Funny Show"])
    }
}
