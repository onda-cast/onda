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

    func test_smartSearch_filtersBySpeakerAndShow() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")

        func makeShow(_ title: String, guid: String, speaker: String) throws -> Episode {
            let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid).xml")!, title: title,
                              author: "A", artworkURL: nil, category: "Tech", itunesId: nil,
                              isSubscribed: true)
            let ep = Episode(guid: guid, title: "Ep", publishDate: .now, duration: 100,
                             audioURL: URL(string: "https://ex.com/\(guid).mp3")!, notes: "")
            ep.podcast = pod
            let tr = Transcript(source: "published", language: "en")
            tr.episode = ep; ep.transcript = tr
            let cue = TranscriptCue(startTime: 10, endTime: 12,
                                    text: "the gold standard era", speaker: speaker)
            cue.transcript = tr; tr.cues = [cue]
            ctx.insert(pod); ctx.insert(ep); ctx.insert(tr); ctx.insert(cue)
            try ctx.save()
            try index.upsert(SearchDoc(kind: "cue", episodeGuid: guid, startTime: 10,
                                       body: "the gold standard era"))
            return ep
        }

        _ = try makeShow("The Signal", guid: "sig", speaker: "Tracy Alloway")
        _ = try makeShow("Slow Burn Kitchen", guid: "sbk", speaker: "Joe")

        let search = TranscriptSearch(modelContext: ctx, index: index)
        let shows = ["The Signal", "Slow Burn Kitchen"]

        // Speaker + show filters both applied from natural phrasing.
        let hits = search.smartSearch("gold standard by Tracy in The Signal", knownShows: shows)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.showTitle, "The Signal")

        // Show-only filter.
        let kitchenHits = search.smartSearch("gold in slow burn kitchen", knownShows: shows)
        XCTAssertEqual(kitchenHits.count, 1)
        XCTAssertEqual(kitchenHits.first?.showTitle, "Slow Burn Kitchen")

        // No filters: both shows hit.
        XCTAssertEqual(search.smartSearch("gold standard", knownShows: shows).count, 2)

        // Speaker filter excludes non-matching speaker cues.
        XCTAssertTrue(search.smartSearch("gold by Zelda", knownShows: shows).isEmpty)
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
