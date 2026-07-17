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

    func test_skipSilenceSetting_seeksOnDetectedSilence() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        ep.podcast?.settings?.skipSilence = true
        pm.play(ep)
        engine.emitTime(100)
        // Feed sustained silence via the engine RMS hook.
        for _ in 0..<10 { engine.onRMS?(0.001, 0.1) }
        XCTAssertGreaterThan(engine.currentTimeSeconds, 100, "a silence skip advanced position")
    }

    func test_adActive_trueInsideAdChapter_whenChaptersPresent() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 2292)
        let c1 = Chapter(title: "Intro", startTime: 0, isAd: false)
        let c2 = Chapter(title: "Sponsor", startTime: 600, isAd: true)
        let c3 = Chapter(title: "Main", startTime: 780, isAd: false)
        for c in [c1, c2, c3] { c.episode = ep; ep.chapters.append(c); ctx.insert(c) }
        pm.play(ep)
        engine.emitTime(100); XCTAssertFalse(pm.adActive)
        engine.emitTime(650); XCTAssertTrue(pm.adActive)
        engine.emitTime(900); XCTAssertFalse(pm.adActive)
    }

    func test_applyAudioSettings_pushesSpeedChangeToEngine_midPlayback() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, speed: 1.0)
        pm.play(ep)
        XCTAssertEqual(engine.rate, 1.0)
        ep.podcast?.settings?.speed = 1.5
        pm.applyAudioSettings()
        XCTAssertEqual(engine.rate, 1.5, "speed changes must reach the engine without restarting playback")
    }

    func test_playApplyingBoost_setsEngineGain() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx)
        ep.podcast?.settings?.voiceBoost = 2
        pm.play(ep)
        XCTAssertEqual(engine.boostGain, 2.4, accuracy: 0.001)
    }

    func test_playClip_startsAtClipStart_andPausesAtClipEnd() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        let clip = Clip(startTime: 100, endTime: 160, text: "", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip); ctx.insert(clip)
        pm.playClip(clip)
        XCTAssertEqual(engine.currentTimeSeconds, 100)
        engine.emitTime(159); XCTAssertTrue(pm.isPlaying)
        engine.emitTime(161)
        XCTAssertFalse(pm.isPlaying, "paused at clip end")
        XCTAssertFalse(ep.played, "clip end must not mark episode played")
    }

    func test_manualSeek_clearsClipBound() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        let clip = Clip(startTime: 100, endTime: 160, text: "", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip); ctx.insert(clip)
        pm.playClip(clip)
        pm.skip(by: 200)              // user takes over
        engine.emitTime(320)
        XCTAssertTrue(pm.isPlaying, "bound cleared by manual skip")
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
