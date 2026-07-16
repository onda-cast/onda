//  TranscriptServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubEngine: AudioTranscribing {
    var cues: [ParsedCue]
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ParsedCue] {
        progress(1.0); return cues
    }
}

@MainActor
final class TranscriptServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }
    private func episode(in ctx: ModelContext, transcriptURL: URL? = nil) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "",
                         transcriptURL: transcriptURL,
                         transcriptType: transcriptURL == nil ? nil : "text/vtt")
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_publishedTranscript_fetchedParsedAndPersisted() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: URL(string: "https://ex.com/t.vtt"))
        let vtt = Data("WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nHello there.".utf8)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in vtt }, localURL: { _ in nil })
        let tr = await svc.transcript(for: ep)
        XCTAssertEqual(tr?.source, "published")
        XCTAssertEqual(tr?.cues.count, 1)
        XCTAssertEqual(tr?.cues.first?.text, "Hello there.")
        // Cached: second call returns the persisted transcript without refetching.
        let again = await svc.transcript(for: ep)
        XCTAssertEqual(again?.cues.count, 1)
    }

    func test_noPublished_butEngineAndDownloaded_usesOnDevice() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let stub = StubEngine(cues: [ParsedCue(startTime: 0, endTime: 2, text: "On device", speaker: nil)])
        let svc = TranscriptService(modelContext: ctx, engine: stub,
                                    fetch: { _ in Data() },
                                    localURL: { _ in URL(fileURLWithPath: "/tmp/e.mp3") })
        let tr = await svc.transcript(for: ep)
        XCTAssertEqual(tr?.source, "ondevice")
        XCTAssertEqual(tr?.cues.first?.text, "On device")
    }

    func test_noPublished_noEngine_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let tr = await svc.transcript(for: ep)
        XCTAssertNil(tr)
    }
}
