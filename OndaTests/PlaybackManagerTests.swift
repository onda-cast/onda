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
    private func makeAppSettings() -> AppSettings {
        let suite = "PMTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }
    private func makeEpisode(in ctx: ModelContext, guid: String = "g", duration: TimeInterval = 1000,
                             intro: Int = 0, outro: Int = 0, speed: Double? = nil,
                             position: TimeInterval = 0) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid)-feed.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let s = ShowSettings.makeDefault(); s.introTrimSec = intro; s.outroTrimSec = outro
        if let speed { s.speed = speed }
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, intro: 30, speed: 1.5)
        pm.play(ep)
        XCTAssertEqual(engine.loadedURL, ep.audioURL)
        XCTAssertEqual(engine.startAt, 30)          // intro trim
        XCTAssertEqual(engine.rate, 1.5)            // show speed
        XCTAssertTrue(pm.isPlaying)
    }

    func test_play_streamingEpisode_triggersBackgroundDownload() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        var downloaded: [String] = []
        pm.ensureDownloaded = { downloaded.append($0.guid) }
        let ep = makeEpisode(in: ctx, guid: "stream-me")
        pm.play(ep)   // no local file in tests → streaming path
        XCTAssertEqual(downloaded, ["stream-me"], "streaming an un-downloaded episode saves it offline")
    }

    func test_playClip_doesNotTriggerDownload() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        var downloaded: [String] = []
        pm.ensureDownloaded = { downloaded.append($0.guid) }
        let ep = makeEpisode(in: ctx, guid: "clip-src", duration: 1000)
        let clip = Clip(startTime: 100, endTime: 160, text: "", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip); ctx.insert(clip)
        pm.playClip(clip)
        XCTAssertTrue(downloaded.isEmpty, "tapping a clip must not pull the whole episode")
    }

    func test_play_resumesFromSavedPositionWhenPastIntro() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, intro: 30, position: 200)
        pm.play(ep)
        XCTAssertEqual(engine.startAt, 200)
    }

    func test_timeUpdate_persistsPosition_andMarksPlayedNear95pct() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g")
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitEnd()
        XCTAssertEqual(pm.currentEpisode?.guid, "g2")
        XCTAssertTrue(pm.isPlaying)
    }

    func test_playFromQueue_removesTappedAndEverythingAbove() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        let a = makeEpisode(in: ctx, guid: "a")
        let b = makeEpisode(in: ctx, guid: "b")
        let c = makeEpisode(in: ctx, guid: "c")
        pm.enqueue(a); pm.enqueue(b); pm.enqueue(c)
        pm.playFromQueue(b)
        XCTAssertEqual(pm.currentEpisode?.guid, "b")
        XCTAssertEqual(pm.queue.map(\.guid), ["c"], "tapped item and everything above it leave the queue")
    }

    func test_sleepTimer_reportsRemaining_andClearsOnOff() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        pm.setSleepTimer(.duration(600))
        let remaining = try XCTUnwrap(pm.sleepRemaining)
        XCTAssertGreaterThan(remaining, 590)
        XCTAssertLessThanOrEqual(remaining, 600)
        pm.setSleepTimer(.off)
        XCTAssertNil(pm.sleepRemaining, "turning the timer off clears the remaining time")
    }

    func test_removeFromQueue_dropsEpisode() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx)
        pm.enqueue(ep)
        XCTAssertEqual(pm.queue.count, 1)
        pm.removeFromQueue(ep)
        XCTAssertEqual(pm.queue.count, 0)
    }

    func test_sleepEndOfEpisode_pausesInsteadOfAdvancing() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx)
        ep.podcast?.settings?.voiceBoost = 2
        pm.play(ep)
        XCTAssertEqual(engine.boostGain, 2.4, accuracy: 0.001)
    }

    func test_playClip_startsAtClipStart_andPausesAtClipEnd() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx)
        pm.play(ep)
        engine.emitTime(100)
        pm.skip(by: 30)
        XCTAssertEqual(engine.currentTimeSeconds, 130, accuracy: 0.5)
        pm.skip(by: -15)
        XCTAssertEqual(engine.currentTimeSeconds, 115, accuracy: 0.5)
    }

    func test_startSmartQueue_playsFirst_queuesRest_replacesExistingQueue() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let stale = makeEpisode(in: ctx, guid: "stale")
        pm.enqueue(stale)
        XCTAssertEqual(pm.queue.count, 1)

        let a = makeEpisode(in: ctx, guid: "a")
        let b = makeEpisode(in: ctx, guid: "b")
        let d = makeEpisode(in: ctx, guid: "d")
        pm.startSmartQueue([a, b, d])

        XCTAssertEqual(engine.loadedURL, a.audioURL, "plays the first entry")
        XCTAssertTrue(pm.isPlaying)
        XCTAssertEqual(pm.queue.map(\.guid), ["b", "d"], "rest materialized into the queue, stale entry gone")

        let items = try ctx.fetch(FetchDescriptor<QueueItem>())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.compactMap { $0.episode?.guid }), ["b", "d"])
    }

    func test_startSmartQueue_emptyList_isNoOp() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.startSmartQueue([])
        XCTAssertNil(engine.loadedURL)
        XCTAssertFalse(pm.isPlaying)
    }
}

// MARK: - Global defaults, seek intervals, Smart Resume, autoplay
extension PlaybackManagerTests {
    func test_play_usesGlobalDefaultSpeed_whenShowHasNoOverride() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.defaultSpeed = 1.75
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep = makeEpisode(in: ctx)          // makeDefault() → all-nil overrides
        pm.play(ep)
        XCTAssertEqual(engine.rate, 1.75)
    }

    func test_skipForwardAndBack_useConfiguredIntervals() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.seekForwardSec = 45; app.seekBackSec = 10
        app.seekAccelerationEnabled = false
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep = makeEpisode(in: ctx, duration: 1000, position: 100)
        pm.play(ep)
        pm.skipForward()
        XCTAssertEqual(pm.positionSeconds, 145, accuracy: 0.01)
        pm.skipBack()
        XCTAssertEqual(pm.positionSeconds, 135, accuracy: 0.01)
    }

    func test_rapidSkips_accelerate_whenEnabled() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()      // acceleration on by default; forward = 30
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        pm.now = { clock }
        let ep = makeEpisode(in: ctx, duration: 10_000, position: 100)
        pm.play(ep)
        pm.skipForward()                                   // 30 → 130
        clock = clock.addingTimeInterval(0.5)
        pm.skipForward()                                   // 60 → 190
        XCTAssertEqual(pm.positionSeconds, 190, accuracy: 0.01)
    }

    func test_smartResumeRewind_scalesWithPauseLength() {
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 30), 0)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 5 * 60), 5)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 60 * 60), 15)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 5 * 3600), 30)
    }

    func test_resumeAfterLongPause_rewindsWhenSmartResumeOn() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()   // smartResumeEnabled defaults to true
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        pm.now = { clock }
        let ep = makeEpisode(in: ctx, duration: 1000, position: 500)
        pm.play(ep)
        pm.togglePlayPause()                      // pause at 500
        clock = clock.addingTimeInterval(10 * 60) // 10 minutes later
        pm.togglePlayPause()                      // resume
        XCTAssertEqual(pm.positionSeconds, 495, accuracy: 0.01)   // 5s rewind
    }

    func test_resumeAfterShortPause_doesNotRewind() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        pm.now = { clock }
        let ep = makeEpisode(in: ctx, duration: 1000, position: 500)
        pm.play(ep)
        pm.togglePlayPause()
        clock = clock.addingTimeInterval(20)
        pm.togglePlayPause()
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.01)
    }

    func test_episodeEnd_stopsInsteadOfAdvancing_whenAutoplayOff() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.autoplayNext = false
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep1 = makeEpisode(in: ctx, guid: "a")
        let ep2 = makeEpisode(in: ctx, guid: "b")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitEnd()
        XCTAssertFalse(pm.isPlaying)
        XCTAssertTrue(ep1.played)
        XCTAssertEqual(pm.queue.count, 1)          // queue untouched
        XCTAssertEqual(pm.currentEpisode?.guid, "a")
    }
}

// MARK: - Cold-launch restore
extension PlaybackManagerTests {
    func test_restoreLastEpisode_reloadsLastPlayedPaused() throws {
        let ctx = try makeContext()
        let ep = makeEpisode(in: ctx, guid: "resume-me", position: 120)
        // Prior session: play() records the guid; pause persists the position.
        let pm1 = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        pm1.play(ep)
        pm1.togglePlayPause()

        // Fresh launch over the same store: restore brings it back, paused, at the saved position.
        let engine = FakeEngine()
        let pm2 = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm2.restoreLastEpisode()
        XCTAssertEqual(pm2.currentEpisode?.guid, "resume-me")
        XCTAssertFalse(pm2.isPlaying, "restore must never autoplay")
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(engine.loadedURL, ep.audioURL)
        XCTAssertEqual(engine.startAt, 120, "resumes from the saved position")
        UserDefaults.standard.removeObject(forKey: "lastPlayedEpisodeGuid")
    }

    func test_restoreLastEpisode_noOpWhenAlreadyPlaying() throws {
        let ctx = try makeContext()
        let ep = makeEpisode(in: ctx, guid: "current")
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        pm.play(ep)
        _ = makeEpisode(in: ctx, guid: "other")
        UserDefaults.standard.set("other", forKey: "lastPlayedEpisodeGuid")
        pm.restoreLastEpisode()   // something is already loaded
        XCTAssertEqual(pm.currentEpisode?.guid, "current", "restore never clobbers an active episode")
        UserDefaults.standard.removeObject(forKey: "lastPlayedEpisodeGuid")
    }
}
