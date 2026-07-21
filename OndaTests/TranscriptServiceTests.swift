//  TranscriptServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubEngine: AudioTranscribing {
    var cues: [ParsedCue]
    func transcribe(fileURL _: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ParsedCue] {
        progress(1.0); return cues
    }
}

/// Counts how many times the engine is actually invoked, and yields once mid-run so a
/// concurrently-issued second request has a chance to (incorrectly) start its own run.
private final class CountingEngine: AudioTranscribing, @unchecked Sendable {
    var calls = 0
    let cues: [ParsedCue]
    init(cues: [ParsedCue]) {
        self.cues = cues
    }

    func transcribe(fileURL _: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ParsedCue] {
        calls += 1
        await Task.yield()
        progress(1.0)
        return cues
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

    // Regression: reopening the sheet or tapping Transcribe while a run is in flight used to
    // start a SECOND concurrent engine pass (bar flicker; reopened sheet showed no progress).
    // Concurrent requests for the same episode must share one run, and isTranscribing must clear.
    func test_concurrentRequests_dedupeToSingleEngineRun() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let engine = CountingEngine(cues: [ParsedCue(startTime: 0, endTime: 2, text: "x", speaker: nil)])
        let svc = TranscriptService(modelContext: ctx, engine: engine,
                                    fetch: { _ in Data() },
                                    localURL: { _ in URL(fileURLWithPath: "/tmp/e.mp3") })
        let a = Task { @MainActor in _ = await svc.transcript(for: ep) }
        let b = Task { @MainActor in _ = await svc.transcript(for: ep) }
        await a.value
        await b.value
        XCTAssertEqual(engine.calls, 1, "concurrent requests share one engine run, not two")
        XCTAssertNotNil(ep.transcript, "the shared run persisted the transcript")
        XCTAssertFalse(svc.isTranscribing(ep), "the in-flight entry is cleared after completion")
    }

    func test_persist_fiveThousandCues_completesQuickly() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let cues = (0 ..< 5000).map {
            ParsedCue(startTime: Double($0), endTime: Double($0) + 1,
                      text: "cue number \($0)", speaker: nil)
        }
        let start = Date()
        let tr = svc.persist(cues: cues, for: ep, source: "published")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(tr.cues.count, 5000)
        // Regression guard for the quadratic relationship-append that hung the main
        // thread on device (watchdog kill). Generous bound: linear persist is well under it.
        XCTAssertLessThan(elapsed, 5.0, "bulk cue persist took \(elapsed)s — quadratic regression?")
    }

    func test_noPublished_noEngine_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let tr = await svc.transcript(for: ep)
        XCTAssertNil(tr)
    }

    func test_persist_indexesCuesForSearch() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let index = try SearchIndex(path: ":memory:")
        let svc = TranscriptService(modelContext: ctx, engine: nil, fetch: { _ in Data() },
                                    localURL: { _ in nil }, index: index)
        let cues = [ParsedCue(startTime: 0, endTime: 2, text: "octopus cognition is wild", speaker: nil)]
        _ = svc.persist(cues: cues, for: ep, source: "published")
        let hits = try index.search("octopus")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.episodeGuid, "g")
    }

    func test_persist_reindexing_clearsStaleCuesForSameEpisode() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let index = try SearchIndex(path: ":memory:")
        let svc = TranscriptService(modelContext: ctx, engine: nil, fetch: { _ in Data() },
                                    localURL: { _ in nil }, index: index)
        _ = svc.persist(cues: [ParsedCue(startTime: 0, endTime: 2, text: "first version", speaker: nil)],
                        for: ep, source: "published")
        _ = svc.persist(cues: [ParsedCue(startTime: 0, endTime: 2, text: "second version", speaker: nil)],
                        for: ep, source: "published")
        XCTAssertTrue(try index.search("first").isEmpty)
        XCTAssertEqual(try index.search("second").count, 1)
    }

    func test_persist_carriesWordTimingThrough_whenPresent() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let words = [WordTiming(text: "on", startTime: 0, endTime: 0.3),
                     WordTiming(text: "device", startTime: 0.3, endTime: 0.9)]
        let cues = [ParsedCue(startTime: 0, endTime: 0.9, text: "on device", speaker: nil, words: words)]
        let tr = svc.persist(cues: cues, for: ep, source: "ondevice")
        XCTAssertEqual(tr.cues.first?.words, words)
    }

    func test_persist_wordsNil_whenSourceIsPublished() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let cues = [ParsedCue(startTime: 0, endTime: 3, text: "Hello there.", speaker: nil)]
        let tr = svc.persist(cues: cues, for: ep, source: "published")
        XCTAssertNil(tr.cues.first?.words)
    }
}

// MARK: - Background completion notice

extension TranscriptServiceTests {
    func test_backgroundNotice_postedOnSuccess_onlyWhenRequested() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let stub = StubEngine(cues: [ParsedCue(startTime: 0, endTime: 2, text: "Hi", speaker: nil)])
        let svc = TranscriptService(modelContext: ctx, engine: stub,
                                    fetch: { _ in Data() },
                                    localURL: { _ in URL(fileURLWithPath: "/tmp/e.mp3") })
        // Not requested → no notice.
        _ = await svc.transcript(for: ep)
        XCTAssertNil(svc.completionNotice)

        // Requested ("Continue in background") → notice with the episode title.
        let ep2 = episode(in: ctx, transcriptURL: nil)
        ep2.transcript = nil
        svc.notifyOnCompletion(of: ep2)
        _ = await svc.transcript(for: ep2)
        XCTAssertEqual(svc.completionNotice, "Transcript ready — E")
    }

    func test_backgroundNotice_postedOnFailure() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let stub = StubEngine(cues: [])   // empty result → failure path
        let svc = TranscriptService(modelContext: ctx, engine: stub,
                                    fetch: { _ in Data() },
                                    localURL: { _ in URL(fileURLWithPath: "/tmp/e.mp3") })
        svc.notifyOnCompletion(of: ep)
        _ = await svc.transcript(for: ep)
        XCTAssertEqual(svc.completionNotice, "Transcription failed — E")
    }
}
