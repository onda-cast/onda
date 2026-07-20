//  ClipServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ClipServiceTests: XCTestCase {
    private func env() throws -> (ModelContext, Episode) {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        for (i, word) in ["alpha", "beta", "gamma", "delta"].enumerated() {
            let cue = TranscriptCue(startTime: Double(i) * 10, endTime: Double(i + 1) * 10,
                                    text: word, speaker: nil)
            cue.transcript = tr; tr.cues.append(cue); ctx.insert(cue)
        }
        ctx.insert(ep); ctx.insert(tr); try ctx.save()
        return (ctx, ep)
    }

    func test_makeClip_snapshotsTextFromTranscript() throws {
        let (ctx, ep) = try env()
        let svc = ClipService(modelContext: ctx)
        let clip = svc.makeClip(episode: ep, requestedStart: 12, requestedEnd: 24,
                                note: "insight!", needsReview: false)
        XCTAssertEqual(clip.text, "beta gamma")
        XCTAssertEqual(clip.startTime, 10); XCTAssertEqual(clip.endTime, 30)
        XCTAssertEqual(clip.note, "insight!")
    }

    func test_quickClip_trailingWindow_needsReview() throws {
        let (ctx, ep) = try env()
        let svc = ClipService(modelContext: ctx)
        let clip = svc.quickClip(episode: ep, at: 38)
        XCTAssertTrue(clip.needsReview)
        XCTAssertEqual(clip.startTime, 0, "45s window from 38 clamps to 0, snaps to cue starts")
        XCTAssertTrue(clip.text.contains("alpha") && clip.text.contains("delta"))
    }

    // Regression: a quick-clip taken in the first moment of an episode (e.g. lock-screen bookmark
    // at position ≈ 0) used to produce start == end ≈ 0 — a zero-length clip that exports as
    // silent audio with no error. It must span at least the minimum clip length.
    func test_quickClip_nearStart_isNotZeroLength() throws {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let ep = Episode(guid: "z", title: "E", publishDate: .now, duration: 600,
                         audioURL: URL(string: "https://ex.com/z.mp3")!, notes: "")   // no transcript cues
        ctx.insert(ep); try ctx.save()
        let svc = ClipService(modelContext: ctx)
        let clip = svc.quickClip(episode: ep, at: 0.2)
        XCTAssertGreaterThanOrEqual(clip.endTime - clip.startTime, ClipReviewSheet.minLength,
                                    "a quick-clip at the very start must still meet the minimum length")
    }

    func test_search_matchesTextAndNote() throws {
        let (ctx, ep) = try env()
        let svc = ClipService(modelContext: ctx)
        _ = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10,
                         note: "remember this", needsReview: false)
        XCTAssertEqual(svc.search("alpha").count, 1)
        XCTAssertEqual(svc.search("remember").count, 1)
        XCTAssertEqual(svc.search("zzz").count, 0)
    }

    func test_makeClip_indexesTextAndNote() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10,
                                note: "remember this", needsReview: false)
        let byText = try index.search("alpha")
        let byNote = try index.search("remember")
        XCTAssertEqual(byText.first?.startTime, clip.startTime)
        XCTAssertEqual(byNote.count, 1)
    }

    func test_updateNote_reindexesWithNewNote() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10, note: "old note", needsReview: true)
        svc.updateNote(clip, note: "new note")
        XCTAssertEqual(clip.note, "new note")
        XCTAssertFalse(clip.needsReview)
        XCTAssertTrue(try index.search("old").isEmpty)
        XCTAssertEqual(try index.search("new note").count, 1)
    }

    func test_delete_removesFromIndex() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10, note: "findable", needsReview: false)
        svc.delete(clip)
        XCTAssertTrue(try index.search("findable").isEmpty)
    }

    func test_makeClipExact_storesExactTimes_noSnapping() throws {
        let (ctx, ep) = try env()
        let svc = ClipService(modelContext: ctx)
        let clip = svc.makeClipExact(episode: ep, start: 12, end: 24, text: "beta gamma",
                                     note: nil, needsReview: false)
        XCTAssertEqual(clip.startTime, 12, "exact time — NOT snapped out to cue start 10")
        XCTAssertEqual(clip.endTime, 24, "exact time — NOT snapped out to cue end 30")
        XCTAssertEqual(clip.text, "beta gamma")
        XCTAssertFalse(clip.needsReview)
    }

    func test_makeClipExact_indexesBody() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        _ = svc.makeClipExact(episode: ep, start: 12, end: 24, text: "beta gamma",
                              note: "sharp insight", needsReview: false)
        XCTAssertEqual(try index.search("beta").count, 1)
        XCTAssertEqual(try index.search("sharp").count, 1)
    }

    func test_updateClip_retimes_clearsNeedsReview_andReindexesUnderNewKey() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        // Lock-screen-style clip: startTime 0, text "alpha", flagged for review.
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10,
                                note: nil, needsReview: true)
        svc.updateClip(clip, start: 15, end: 25, text: "beta gamma", note: "kept")
        XCTAssertEqual(clip.startTime, 15)
        XCTAssertEqual(clip.endTime, 25)
        XCTAssertEqual(clip.note, "kept")
        XCTAssertFalse(clip.needsReview)
        let hits = try index.search("beta")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startTime, 15, "index doc re-keyed to the new start time")
        XCTAssertTrue(try index.search("alpha").isEmpty,
                      "stale doc under the old startTime key is gone")
    }
}
