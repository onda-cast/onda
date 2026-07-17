//  TranscriptSearchTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class TranscriptSearchTests: XCTestCase {
    func test_search_findsMatchingCues_inSubscribedShows() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "g", startTime: 10,
                                   body: "the slow death of the homepage"))

        let hits = TranscriptSearch(modelContext: ctx, index: index).search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertEqual(hits.first?.showTitle, "The Signal")
        XCTAssertEqual(hits.first?.kind, "cue")
    }

    func test_search_excludesUnsubscribedShows() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: false)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "g", startTime: 10, body: "homepage"))

        XCTAssertTrue(TranscriptSearch(modelContext: ctx, index: index).search("homepage").isEmpty)
    }

    func test_search_includesClipHits() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "clip", episodeGuid: "g", startTime: 20, body: "a great insight"))

        let hits = TranscriptSearch(modelContext: ctx, index: index).search("insight")
        XCTAssertEqual(hits.first?.kind, "clip")
    }
}
