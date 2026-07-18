//  ArticleModelTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ArticleModelTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_defaults_feedSourcedModels() throws {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        XCTAssertFalse(pod.isLocal)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        XCTAssertEqual(ep.sourceType, "feed")
        XCTAssertNil(ep.articleSource)
        XCTAssertNil(ShowSettings.makeDefault().ttsVoiceIdentifier)
    }

    func test_articleSource_persistsAndCascadesWithEpisode() throws {
        let ctx = try makeContext()
        let ep = Episode(guid: "article-1", title: "T", publishDate: .now, duration: 10,
                         audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), notes: "")
        ep.sourceType = "article"
        ctx.insert(ep)
        let src = ArticleSource(sourceURL: URL(string: "https://ex.com/story")!,
                                siteName: "Example", addedAt: .now)
        src.episode = ep
        ep.articleSource = src
        ctx.insert(src)
        try ctx.save()

        XCTAssertEqual(ep.articleSource?.siteName, "Example")
        ctx.delete(ep)
        try ctx.save()
        let remaining = try ctx.fetch(FetchDescriptor<ArticleSource>())
        XCTAssertTrue(remaining.isEmpty, "ArticleSource must cascade-delete with its Episode")
    }
}
