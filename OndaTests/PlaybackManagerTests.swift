//  PlaybackManagerTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class FakeEngine: PlayerEngine {
    var rate: Float = 1
    var currentTimeSeconds: TimeInterval = 0
    var onEndOfItem: (() -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onRMS: ((Float, Double) -> Void)?
    private(set) var boostGain: Float = 1.0
    func setBoostGain(_ gain: Float) { boostGain = gain }
    private(set) var loadedURL: URL?
    private(set) var startAt: TimeInterval = 0
    private(set) var playing = false
    func load(url: URL, startAt: TimeInterval) { loadedURL = url; self.startAt = startAt; currentTimeSeconds = startAt }
    func play() { playing = true }
    func pause() { playing = false }
    func seek(to seconds: TimeInterval) { currentTimeSeconds = max(0, seconds) }
    // test helpers
    func emitTime(_ t: TimeInterval) { currentTimeSeconds = t; onTimeUpdate?(t) }
    func emitEnd() { onEndOfItem?() }
}

@MainActor
final class PlaybackManagerTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }
    private func makeEpisode(in ctx: ModelContext, guid: String = "g", duration: TimeInterval = 1000,
                             intro: Int = 0, outro: Int = 0, speed: Double = 1.0,
                             position: TimeInterval = 0) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid)-feed.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let s = ShowSettings.makeDefault(); s.introTrimSec = intro; s.outroTrimSec = outro; s.speed = speed
        s.podcast = pod; pod.settings = s
        let ep = Episode(guid: guid, title: "E", publishDate: .now, duration: duration,
                         audioURL: URL(string: "https://ex.com/\(guid).mp3")!, notes: "", playbackPosition: position)
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(s); ctx.insert(ep)
        return ep
    }

    func test_play_streamsAudio_appliesSpeed_andStartsAtIntroTrim() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, intro: 30, speed: 1.5)
        pm.play(ep)
        XCTAssertEqual(engine.loadedURL, ep.audioURL)
        XCTAssertEqual(engine.startAt, 30)          // intro trim
        XCTAssertEqual(engine.rate, 1.5)            // show speed
        XCTAssertTrue(pm.isPlaying)
    }

    func test_play_resumesFromSavedPositionWhenPastIntro() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, intro: 30, position: 200)
        pm.play(ep)
        XCTAssertEqual(engine.startAt, 200)
    }

    func test_timeUpdate_persistsPosition_andMarksPlayedNear95pct() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        engine.emitTime(500)
        XCTAssertEqual(ep.playbackPosition, 500, accuracy: 0.5)
        XCTAssertFalse(ep.played)
        engine.emitTime(960)   // > 95%
        XCTAssertTrue(ep.played)
    }

    func test_endOfItem_advancesToNextQueueItem() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep1 = makeEpisode(in: ctx, guid: "g")
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitEnd()
        XCTAssertEqual(pm.currentEpisode?.guid, "g2")
        XCTAssertTrue(pm.isPlaying)
    }

    func test_removeFromQueue_dropsEpisode() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx)
        let ep = makeEpisode(in: ctx)
        pm.enqueue(ep)
        XCTAssertEqual(pm.queue.count, 1)
        pm.removeFromQueue(ep)
        XCTAssertEqual(pm.queue.count, 0)
    }

    func test_sleepEndOfEpisode_pausesInsteadOfAdvancing() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep1 = makeEpisode(in: ctx, guid: "g")
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1); pm.enqueue(ep2)
        pm.setSleepTimer(.endOfEpisode)
        engine.emitEnd()
        XCTAssertEqual(pm.currentEpisode?.guid, "g", "stays on the finished episode, does not auto-advance")
        XCTAssertFalse(pm.isPlaying)
    }

    func test_skip_movesPositionInFeedTime() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx)
        pm.play(ep)
        engine.emitTime(100)
        pm.skip(by: 30)
        XCTAssertEqual(engine.currentTimeSeconds, 130, accuracy: 0.5)
        pm.skip(by: -15)
        XCTAssertEqual(engine.currentTimeSeconds, 115, accuracy: 0.5)
    }
}
