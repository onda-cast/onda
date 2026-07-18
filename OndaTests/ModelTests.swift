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
        let pub = Podcast(feedURL: URL(string: "https://ex.com/pub.xml")!, title: "Pub",
                          author: "A", artworkURL: nil, category: "Tech", itunesId: 1)
        let priv = Podcast(feedURL: URL(string: "https://ex.com/priv.xml?token=s3cret")!, title: "Priv",
                           author: "A", artworkURL: nil, category: "Tech", itunesId: nil,
                           isPrivateFeed: true)
        ctx.insert(pub); ctx.insert(priv); try ctx.save()
        XCTAssertFalse(pub.isPrivateFeed, "default is public")
        XCTAssertTrue(priv.isPrivateFeed)
    }

    func test_insertPodcastWithEpisode_persistsRelationship() throws {
        let ctx = try inMemoryContext()
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!,
                          title: "The Signal", author: "Ex", artworkURL: nil,
                          category: "Technology", itunesId: 42)
        let ep = Episode(guid: "g1", title: "Ep 1", publishDate: .now,
                         duration: 100, audioURL: URL(string: "https://ex.com/1.mp3")!,
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
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
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

    func test_showSettingsDefault_hasExpectedValues() {
        let s = ShowSettings.makeDefault()
        XCTAssertEqual(s.speed, 1.0)
        XCTAssertEqual(s.voiceBoost, 0)
        XCTAssertFalse(s.skipSilence)
        XCTAssertEqual(s.adSkipMode, "off")
        XCTAssertFalse(s.autoDownload)
        XCTAssertEqual(s.introTrimSec, 0)
        XCTAssertEqual(s.outroTrimSec, 0)
        XCTAssertEqual(s.notifMode, "all")
    }

    func test_chapter_defaultsToFeedSource() throws {
        let ctx = try inMemoryContext()
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        let feedChapter = Chapter(title: "Intro", startTime: 0, isAd: false)
        let generatedChapter = Chapter(title: "AI: Setup", startTime: 120, isAd: false, source: "generated")
        feedChapter.episode = ep; ep.chapters.append(feedChapter)
        generatedChapter.episode = ep; ep.chapters.append(generatedChapter)
        ctx.insert(ep); ctx.insert(feedChapter); ctx.insert(generatedChapter)
        try ctx.save()
        XCTAssertEqual(feedChapter.source, "feed")
        XCTAssertEqual(generatedChapter.source, "generated")
    }
}
