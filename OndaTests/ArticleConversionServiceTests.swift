//  ArticleConversionServiceTests.swift
// swiftlint:disable force_try
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

/// Coordinates a gated fake render call so tests can deterministically catch a conversion
/// mid-flight: waitForEntry() suspends until the renderer is actually blocked inside render(),
/// and release() lets it proceed. Cancellation is detected by the renderer itself (via
/// Task.checkCancellation() in its poll loop) without needing an explicit release.
private actor Gate {
    private(set) var isReleased = false
    /// Counts every render() call that has reached the gate, including repeat entries after the
    /// first (unlike `entered`/`waitForEntry`, which only track the first). Tests use this to
    /// assert a conversion attempt did or didn't start a new renderer invocation.
    private(set) var enterCount = 0
    private var entered = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func enter() {
        enterCount += 1
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() { isReleased = true }
}

/// A renderer that blocks inside render() until the test releases its Gate, polling for
/// cancellation in the meantime so a cancelled Task unwinds promptly without waiting for release.
private struct GatedRenderer: ArticleSpeechRendering {
    let gate: Gate
    var duration: TimeInterval = 3.0
    var cues: [ParsedCue] = [ParsedCue(startTime: 0, endTime: 1.5, text: "One.", speaker: nil)]

    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio {
        await gate.enter()
        while await !gate.isReleased {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: outputURL)
        progress(1)
        return RenderedArticleAudio(fileURL: outputURL, duration: duration, cues: cues)
    }
}

@MainActor
final class ArticleConversionServiceTests: XCTestCase {
    /// Polls a condition with a bounded timeout instead of a single arbitrary sleep. Used both
    /// to wait for a conversion to settle and to confirm a bad state never appears.
    @discardableResult
    private func poll(timeout: TimeInterval = 1.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Same as poll(), but for conditions that read actor-isolated state (e.g. a Gate's
    /// enterCount) and so must themselves be async.
    @discardableResult
    private func pollAsync(timeout: TimeInterval = 1.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makeService(ctx: ModelContext,
                             extract: @escaping ArticleConversionService.Extract,
                             renderer: ArticleSpeechRendering = FakeRenderer(),
                             queue: PendingArticlesQueue = PendingArticlesQueue(containerURL: nil))
        -> ArticleConversionService {
        let ts = TranscriptService(modelContext: ctx, engine: nil,
                                   fetch: { _ in Data() }, localURL: { _ in nil })
        return ArticleConversionService(
            modelContext: ctx, extract: extract, renderer: renderer,
            persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") },
            queue: queue)
    }

    private func tempQueue() -> PendingArticlesQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("svc-queue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingArticlesQueue(containerURL: dir)
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

    func test_dismissThenReAdd_whileFirstConversionInFlight_producesExactlyOneEpisode() async throws {
        let ctx = try makeContext()
        let gate = Gate()
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: GatedRenderer(gate: gate))
        let url = URL(string: "https://example.com/race")!

        svc.add(url: url)
        await gate.waitForEntry()   // task A is genuinely in flight, blocked inside render()
        svc.dismiss(url: url)
        svc.add(url: url)          // task B starts concurrently while A is still unwinding

        let bEntered = await pollAsync { await gate.enterCount == 2 }
        XCTAssertTrue(bEntered, "task B did not reach render() within the timeout")

        // An ordinary third add() while B is still gated must see "already converting" and be a
        // no-op — previously the URL-keyed cleanup let a stale task A clobber B's handle here,
        // opening a window where this add() would start a third, duplicate-producing task.
        svc.add(url: url)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let countBeforeRelease = await gate.enterCount
        XCTAssertEqual(countBeforeRelease, 2,
                       "a third add() while a conversion is in flight must not start another one")

        await gate.release()       // lets both A (which self-cancels) and B proceed

        let settled = await poll { svc.pending.isEmpty }
        XCTAssertTrue(settled, "conversion did not settle within the timeout")

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1, "dismiss + re-add + a concurrent add() must not duplicate the episode")
        XCTAssertTrue(svc.pending.isEmpty)
        XCTAssertNil(svc.pending.first(where: { $0.id == url })?.failure)

        if let ep = eps.first {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }

    func test_retry_whileConversionInFlight_isNoOpAndKeepsPendingRow() async throws {
        let ctx = try makeContext()
        let gate = Gate()
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: GatedRenderer(gate: gate))
        let url = URL(string: "https://example.com/retry-in-flight")!

        svc.add(url: url)
        await gate.waitForEntry()   // conversion is genuinely in flight, blocked inside render()

        svc.retry(url: url)         // retry while in flight must be a no-op, not remove the row

        XCTAssertEqual(svc.pending.count, 1, "retry while in flight must not remove the active row")
        XCTAssertEqual(svc.pending.first?.id, url)
        XCTAssertNil(svc.pending.first?.failure)

        try? await Task.sleep(nanoseconds: 100_000_000)
        let countBeforeRelease = await gate.enterCount
        XCTAssertEqual(countBeforeRelease, 1, "retry while in flight must not start a second conversion")

        await gate.release()

        let settled = await poll { svc.pending.isEmpty }
        XCTAssertTrue(settled, "conversion did not settle within the timeout")

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1)
        XCTAssertTrue(svc.pending.isEmpty)

        if let ep = eps.first {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }

    func test_dismiss_whileConversionInFlight_cancelsWithoutResurrectingOrCreatingEpisode() async throws {
        let ctx = try makeContext()
        let gate = Gate()
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: GatedRenderer(gate: gate))
        let url = URL(string: "https://example.com/cancel")!

        svc.add(url: url)
        await gate.waitForEntry()   // conversion is genuinely in flight, blocked inside render()
        svc.dismiss(url: url)
        await gate.release()        // let the (already-cancelled) render() call unwind

        // Give the cancelled task a bounded window to finish; a bug here would either
        // resurrect the pending row or insert an episode from a cancelled conversion.
        await poll(timeout: 0.3) { (try? ctx.fetch(FetchDescriptor<Episode>()).isEmpty) == false }

        XCTAssertTrue(svc.pending.isEmpty, "a cancelled conversion must not resurrect the dismissed row")
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty,
                      "a cancelled conversion must not create an episode")
    }

    func test_successfulConversion_removesURLFromPersistentQueue() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        let url = URL(string: "https://example.com/persist-ok")!
        queue.append(url)

        await svc.convert(url)

        XCTAssertTrue(queue.entries().isEmpty, "success must clear the durable entry")
        let ep = try ctx.fetch(FetchDescriptor<Episode>()).first
        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep?.guid ?? "")))
    }

    func test_failedConversion_recordsAttemptAndKeepsEntry() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed },
                              queue: queue)
        let url = URL(string: "https://example.com/persist-fail")!
        svc.add(url: url)   // add() must append to the queue itself
        // Wait for the fire-and-forget task to finish (bounded poll).
        for _ in 0..<100 where svc.pending.first?.failure == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.entries(), [.init(url: url, attempts: 1)])
    }

    func test_dismiss_removesEntryFromQueue() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed },
                              queue: queue)
        let url = URL(string: "https://example.com/persist-dismiss")!
        svc.add(url: url)
        for _ in 0..<100 where svc.pending.first?.failure == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        svc.dismiss(url: url)
        XCTAssertTrue(queue.entries().isEmpty)
    }

    func test_resumePersisted_convertsSubCapAndFlagsCappedEntries() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let fresh = URL(string: "https://example.com/fresh")!
        let capped = URL(string: "https://example.com/capped")!
        queue.append(fresh)
        queue.append(capped)
        for _ in 0..<ArticleConversionService.maxAutoAttempts { queue.recordAttempt(capped) }

        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        svc.resumePersisted()

        // capped: failed row immediately, no conversion started for it
        XCTAssertEqual(svc.pending.first(where: { $0.id == capped })?.failure,
                       "Conversion failed 3 times — retry to try again.")
        // fresh: converts to an episode; wait bounded for the async add() task
        for _ in 0..<200 {
            if (try? ctx.fetch(FetchDescriptor<Episode>()))?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1, "only the sub-cap entry converts")
        XCTAssertEqual(queue.entries().map(\.url), [capped], "fresh removed on success; capped kept")
        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: eps[0].guid)))
    }

    func test_processQueueForBackground_convertsSubCapEntriesSequentially() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let a = URL(string: "https://example.com/bg-a")!
        let b = URL(string: "https://example.com/bg-b")!
        let capped = URL(string: "https://example.com/bg-capped")!
        queue.append(a)
        queue.append(b)
        queue.append(capped)
        for _ in 0..<ArticleConversionService.maxAutoAttempts { queue.recordAttempt(capped) }

        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        await svc.processQueueForBackground()

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 2, "both sub-cap entries convert; capped one is skipped")
        XCTAssertEqual(queue.entries().map(\.url), [capped])
        for ep in eps {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }

    func test_processQueueForBackground_skipsInFlightURL() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let url = URL(string: "https://example.com/bg-inflight")!
        queue.append(url)
        let gate = Gate()   // reuse the existing gated fake from the race tests
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: GatedRenderer(gate: gate), queue: queue)
        svc.add(url: url)
        await gate.waitForEntry()   // wait until the gated conversion is genuinely inside render()

        await svc.processQueueForBackground()   // must NOT start a second attempt

        let enterCount = await gate.enterCount
        XCTAssertEqual(enterCount, 1, "background pass must skip the in-flight URL")
        await gate.release()
        let settled = await poll { svc.pending.isEmpty }
        XCTAssertTrue(settled, "conversion did not settle within the timeout")
        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1)
        if let ep = eps.first {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }
}
