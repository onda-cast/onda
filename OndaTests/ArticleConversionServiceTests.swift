//  ArticleConversionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct FakeRenderer: ArticleSpeechRendering {
    var duration: TimeInterval = 3.0
    var cues: [ParsedCue] = [ParsedCue(startTime: 0, endTime: 1.5, text: "One.", speaker: nil),
                             ParsedCue(startTime: 1.5, endTime: 3.0, text: "Two.", speaker: nil)]
    var fails = false

    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio {
        if fails { throw ArticleRenderError.synthesisFailed }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: outputURL)
        progress(1)
        return RenderedArticleAudio(fileURL: outputURL, duration: duration, cues: cues)
    }
}

@MainActor
final class ArticleConversionServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makeService(ctx: ModelContext,
                             extract: @escaping ArticleConversionService.Extract,
                             renderer: ArticleSpeechRendering = FakeRenderer())
        -> ArticleConversionService {
        let ts = TranscriptService(modelContext: ctx, engine: nil,
                                   fetch: { _ in Data() }, localURL: { _ in nil })
        return ArticleConversionService(
            modelContext: ctx, extract: extract, renderer: renderer,
            persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") })
    }

    private let article = ExtractedArticle(title: "The Long Migration", byline: "By Jordan Reyes",
                                           siteName: "Example", textContent: "One. Two.")

    func test_successfulConversion_createsEpisodeWithAllRows() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article })
        let url = URL(string: "https://example.com/terns")!

        await svc.convert(url)

        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
        XCTAssertTrue(pods[0].isLocal)
        XCTAssertTrue(pods[0].isSubscribed)
        XCTAssertEqual(pods[0].title, "Articles")

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1)
        let ep = eps[0]
        XCTAssertEqual(ep.sourceType, "article")
        XCTAssertEqual(ep.title, "The Long Migration")
        XCTAssertEqual(ep.duration, 3.0)
        XCTAssertEqual(ep.podcast?.feedURL, ArticleConversionService.articlesFeedURL)
        XCTAssertEqual(ep.articleSource?.sourceURL, url)
        XCTAssertEqual(ep.downloadedFile?.localFileName,
                       ArticleConversionService.audioFileName(for: ep.guid))
        XCTAssertGreaterThan(ep.downloadedFile?.fileSizeBytes ?? 0, 0)
        XCTAssertEqual(ep.transcript?.source, "tts")
        XCTAssertEqual(ep.transcript?.cues.count, 2)
        XCTAssertTrue(svc.pending.isEmpty)

        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
    }

    func test_extractionFailure_setsFailureAndCreatesNothing() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.noReadableContent })
        let url = URL(string: "https://example.com/paywalled")!

        await svc.convert(url)

        XCTAssertEqual(svc.pending.count, 1)
        XCTAssertEqual(svc.pending[0].failure,
                       ArticleExtractionError.noReadableContent.errorDescription)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Podcast>()).isEmpty,
                      "Articles show must not be created before first success")
    }

    func test_renderFailure_setsFailureAndCreatesNothing() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: FakeRenderer(fails: true))
        await svc.convert(URL(string: "https://example.com/x")!)
        XCTAssertNotNil(svc.pending.first?.failure)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    func test_articlesPodcast_reusedAndResubscribed() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article })
        let pod = svc.articlesPodcast()
        pod.isSubscribed = false   // user "deleted" the Articles show
        let again = svc.articlesPodcast()
        XCTAssertTrue(again.isSubscribed, "adding an article must revive the show")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertNotNil(again.settings, "settings created with the show for the voice picker")
    }

    func test_audioFileName_sanitizesGuid() {
        XCTAssertEqual(ArticleConversionService.audioFileName(for: "article-AB/12:x"),
                       "article_AB_12_x.m4a")
    }

    func test_dismiss_removesPendingItem() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed })
        let url = URL(string: "https://example.com/x")!
        await svc.convert(url)
        XCTAssertEqual(svc.pending.count, 1)
        svc.dismiss(url: url)
        XCTAssertTrue(svc.pending.isEmpty)
    }
}
