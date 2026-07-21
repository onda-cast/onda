//  ModelTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ModelTests: XCTestCase {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(ondaSchema), configurations: config)
        return ModelContext(container)
    }

    func test_podcast_isPrivateFeed_defaultsFalseAndPersists() throws {
        let ctx = try inMemoryContext()
        let pub = try Podcast(feedURL: XCTUnwrap(URL(string: "https://ex.com/pub.xml")), title: "Pub",
                              author: "A", artworkURL: nil, category: "Tech", itunesId: 1)
        let priv = try Podcast(feedURL: XCTUnwrap(URL(string: "https://ex.com/priv.xml?token=s3cret")), title: "Priv",
                               author: "A", artworkURL: nil, category: "Tech", itunesId: nil,
                               isPrivateFeed: true)
        ctx.insert(pub); ctx.insert(priv); try ctx.save()
        XCTAssertFalse(pub.isPrivateFeed, "default is public")
        XCTAssertTrue(priv.isPrivateFeed)
    }

    func test_insertPodcastWithEpisode_persistsRelationship() throws {
        let ctx = try inMemoryContext()
        let pod = try Podcast(feedURL: XCTUnwrap(URL(string: "https://ex.com/f.xml")),
                              title: "The Signal", author: "Ex", artworkURL: nil,
                              category: "Technology", itunesId: 42)
        let ep = try Episode(guid: "g1", title: "Ep 1", publishDate: .now,
                             duration: 100, audioURL: XCTUnwrap(URL(string: "https://ex.com/1.mp3")),
                             notes: "notes")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep)
        try ctx.save()

        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
        XCTAssertEqual(pods.first?.episodes.count, 1)
        XCTAssertEqual(pods.first?.episodes.first?.title, "Ep 1")
    }

    func test_transcript_persistsCuesLinkedToEpisode() throws {
        let ctx = try inMemoryContext()
        let pod = try Podcast(feedURL: XCTUnwrap(URL(string: "https://ex.com/f.xml")), title: "S", author: "A",
                              artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = try Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                             audioURL: XCTUnwrap(URL(string: "https://ex.com/e.mp3")), notes: "")
        ep.podcast = pod
        let tr = Transcript(source: "published", language: "en")
        tr.episode = ep; ep.transcript = tr
        let cue = TranscriptCue(startTime: 0, endTime: 5, text: "Hello", speaker: nil)
        cue.transcript = tr; tr.cues.append(cue)
        for m in [pod, ep] as [any PersistentModel] { ctx.insert(m) }
        ctx.insert(tr); ctx.insert(cue)
        try ctx.save()

        let trs = try ctx.fetch(FetchDescriptor<Transcript>())
        XCTAssertEqual(trs.first?.cues.count, 1)
        XCTAssertEqual(trs.first?.episode?.guid, "g")
    }

    func test_showSettingsDefault_inheritsEveryGlobal() {
        let s = ShowSettings.makeDefault()
        XCTAssertNil(s.speed)
        XCTAssertNil(s.voiceBoost)
        XCTAssertNil(s.skipSilence)
        XCTAssertNil(s.adSkipMode)
        XCTAssertNil(s.autoDownload)
        XCTAssertEqual(s.introTrimSec, 0)
        XCTAssertEqual(s.outroTrimSec, 0)
    }

    func test_chapter_defaultsToFeedSource() throws {
        let ctx = try inMemoryContext()
        let ep = try Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                             audioURL: XCTUnwrap(URL(string: "https://ex.com/e.mp3")), notes: "")
        let feedChapter = Chapter(title: "Intro", startTime: 0, isAd: false)
        let generatedChapter = Chapter(title: "AI: Setup", startTime: 120, isAd: false, source: "generated")
        feedChapter.episode = ep; ep.chapters.append(feedChapter)
        generatedChapter.episode = ep; ep.chapters.append(generatedChapter)
        ctx.insert(ep); ctx.insert(feedChapter); ctx.insert(generatedChapter)
        try ctx.save()
        XCTAssertEqual(feedChapter.source, "feed")
        XCTAssertEqual(generatedChapter.source, "generated")
    }

    func test_bookMention_roundTripsAndCascadesFromEpisode() throws {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let ep = try Episode(guid: "g", title: "E", publishDate: .now, duration: 10,
                             audioURL: XCTUnwrap(URL(string: "https://ex.com/e.mp3")), notes: "")
        ctx.insert(ep)
        let book = BookMention(workKey: "OL123W", title: "Atomic Habits", author: "James Clear",
                               coverURL: nil, sourceTier: "link", timestamp: nil)
        book.episode = ep; ep.bookMentions.append(book)
        ctx.insert(book); try ctx.save()

        ctx.delete(ep); try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BookMention>()).count, 0,
                       "book mentions cascade with their episode")
    }

    // Regression: QueueItem.episode had no inverse relationship on Episode, so it defaulted to
    // .nullify — deleting an episode left an orphaned QueueItem row (episode == nil) behind
    // instead of removing it.
    func test_queueItem_cascadesFromEpisode() throws {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let ep = try Episode(guid: "g", title: "E", publishDate: .now, duration: 10,
                             audioURL: XCTUnwrap(URL(string: "https://ex.com/e.mp3")), notes: "")
        ctx.insert(ep)
        let item = QueueItem(episode: ep, position: 0)
        ep.queueItems.append(item)
        ctx.insert(item); try ctx.save()

        ctx.delete(ep); try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QueueItem>()).count, 0,
                       "queue items cascade with their episode, no orphaned rows")
    }
}
