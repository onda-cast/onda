//  SearchIndexTests.swift
import XCTest
@testable import Onda

@MainActor
final class SearchIndexTests: XCTestCase {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(path: ":memory:")
    }

    func test_upsertAndSearch_findsMatchingBody_withSnippet() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 10,
                                 body: "the slow death of the homepage"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 40,
                                 body: "octopus cognition is wild"))
        let hits = try idx.search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.episodeGuid, "g1")
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertTrue(hits.first?.snippet.localizedCaseInsensitiveContains("homepage") ?? false)
    }

    func test_search_ranksMoreRelevantMatchHigher() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "a", startTime: 0, body: "swift swift swift language"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "b", startTime: 0, body: "swift is nice"))
        let hits = try idx.search("swift")
        XCTAssertEqual(hits.first?.episodeGuid, "a", "denser match should rank first")
    }

    func test_delete_removesExactDoc() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "remember this insight"))
        try idx.delete(kind: "clip", episodeGuid: "g1", startTime: 5)
        XCTAssertTrue(try idx.search("insight").isEmpty)
    }

    func test_deleteAll_removesOnlyMatchingKindAndEpisode() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "alpha"))
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 0, body: "alpha note"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g2", startTime: 0, body: "alpha too"))
        try idx.deleteAll(episodeGuid: "g1", kind: "cue")
        let hits = try idx.search("alpha")
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g1" && $0.kind == "cue" }.count, 0)
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g1" && $0.kind == "clip" }.count, 1)
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g2" }.count, 1)
    }

    func test_upsert_replacesExistingDocAtSameKey() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "first note"))
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "second note"))
        let hits = try idx.search("note")
        XCTAssertEqual(hits.count, 1, "second upsert replaces, doesn't duplicate")
        XCTAssertTrue(try XCTUnwrap(hits.first?.snippet.localizedCaseInsensitiveContains("second")))
    }

    func test_isEmpty_trueUntilFirstInsert() throws {
        let idx = try makeIndex()
        XCTAssertTrue(try idx.isEmpty())
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "hello"))
        XCTAssertFalse(try idx.isEmpty())
    }

    func test_search_shortQuery_returnsEmpty() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "hello world"))
        XCTAssertEqual(try idx.search("h"), [])
    }

    // Regression: a single CJK character is a full word (unlike a single Latin letter), but
    // the 2-char floor used to reject the query outright before it ever reached FTS5, so a
    // one-character Chinese/Japanese/Korean query always returned empty — even when the
    // character appears as a standalone, space-delimited token FTS5 can actually match (as in
    // mixed-language transcripts). Note: fully unspaced CJK text needs a CJK-aware FTS5
    // tokenizer to segment per-character — a separate, larger change; this only removes the
    // artificial length floor that blocked the query before FTS5 even saw it.
    func test_search_singleCJKCharacter_notRejectedByLengthFloor() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0,
                                 body: "the word for sun is 日 in Japanese"))
        XCTAssertFalse(try idx.search("日").isEmpty,
                       "a single CJK character must reach FTS5, not be rejected by the length guard")
    }
}
