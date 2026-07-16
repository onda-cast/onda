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
}
