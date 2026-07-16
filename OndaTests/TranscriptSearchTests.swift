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
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        let c1 = TranscriptCue(startTime: 10, endTime: 12, text: "the slow death of the homepage", speaker: nil)
        let c2 = TranscriptCue(startTime: 40, endTime: 42, text: "octopus cognition is wild", speaker: nil)
        c1.transcript = tr; tr.cues.append(c1)
        c2.transcript = tr; tr.cues.append(c2)
        ctx.insert(pod); ctx.insert(ep); ctx.insert(tr); ctx.insert(c1); ctx.insert(c2)
        try ctx.save()

        let hits = TranscriptSearch(modelContext: ctx).search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertEqual(hits.first?.showTitle, "The Signal")
    }
}
