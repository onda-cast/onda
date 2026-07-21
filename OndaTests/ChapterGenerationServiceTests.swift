//  ChapterGenerationServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubGenerator: ChapterGenerating {
    var result: Result<[ParsedChapter], Error>
    func generateChapters(transcriptText _: String, duration _: TimeInterval) async throws -> [ParsedChapter] {
        try result.get()
    }
}

@MainActor
final class ChapterGenerationServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func episode(in ctx: ModelContext) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 1800,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_canGenerate_requiresNoExistingChaptersAndATranscript() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .success([]))
        let withText = ChapterGenerationService(modelContext: ctx, generator: stub,
                                                hasTranscript: { _ in true }, transcriptText: { _ in "hello" })
        XCTAssertTrue(withText.canGenerate(ep))

        let noText = ChapterGenerationService(modelContext: ctx, generator: stub,
                                              hasTranscript: { _ in false }, transcriptText: { _ in nil })
        XCTAssertFalse(noText.canGenerate(ep))

        ep.chapters.append(Chapter(title: "Existing", startTime: 0))
        XCTAssertFalse(withText.canGenerate(ep), "never offered when the feed already has chapters")
    }

    func test_generate_persistsChaptersTaggedGenerated_neverAd() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .success([
            ParsedChapter(title: "Intro", startTime: 0, isAd: true),   // model can't claim ad — must be forced false
            ParsedChapter(title: "Main topic", startTime: 300, isAd: false),
        ]))
        let svc = ChapterGenerationService(modelContext: ctx, generator: stub,
                                           hasTranscript: { _ in true }, transcriptText: { _ in "a transcript" })
        let chapters = await svc.generate(for: ep)
        XCTAssertEqual(chapters?.count, 2)
        XCTAssertEqual(ep.chapters.count, 2)
        XCTAssertTrue(ep.chapters.allSatisfy { $0.source == "generated" && $0.isAd == false })
    }

    func test_generate_failure_setsLastFailure_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .failure(ChapterGenerationError.unavailable))
        let svc = ChapterGenerationService(modelContext: ctx, generator: stub,
                                           hasTranscript: { _ in true }, transcriptText: { _ in "text" })
        let chapters = await svc.generate(for: ep)
        XCTAssertNil(chapters)
        XCTAssertNotNil(svc.lastFailure["g"])
        XCTAssertTrue(ep.chapters.isEmpty)
    }

    func test_generate_noGenerator_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let svc = ChapterGenerationService(modelContext: ctx, generator: nil,
                                           hasTranscript: { _ in true }, transcriptText: { _ in "text" })
        let chapters = await svc.generate(for: ep)
        XCTAssertNil(chapters)
    }
}
