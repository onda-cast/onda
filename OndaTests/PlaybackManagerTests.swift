//  PlaybackManagerTests.swift
import XCTest
import AVFoundation
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

    // Regression: pressing play on a transcript line must start playback at that line whether or
    // not the episode is already the current one.
    func test_jumpFromTranscript_differentEpisode_loadsAtLineAndPlays() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let playing = makeEpisode(in: ctx, guid: "a", duration: 1000)
        let other = makeEpisode(in: ctx, guid: "b", duration: 1000)
        pm.play(playing)
        pm.jumpFromTranscript(episode: other, to: 300)
        XCTAssertEqual(pm.currentEpisode?.guid, "b", "switches to the tapped episode")
        XCTAssertTrue(pm.isPlaying)
        XCTAssertTrue(engine.playing, "engine is actually playing")
        // Loaded directly at the line (1s of lead-in), not via a post-load seek race.
        XCTAssertEqual(engine.startAt, 299, accuracy: 0.5)
    }

    func test_jumpFromTranscript_sameEpisodePaused_resumesAtLine() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.smartResumeEnabled = true
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep = makeEpisode(in: ctx, guid: "a", duration: 1000)
        pm.play(ep)
        pm.togglePlayPause()                       // pause
        XCTAssertFalse(pm.isPlaying)
        pm.jumpFromTranscript(episode: ep, to: 500)
        XCTAssertTrue(pm.isPlaying, "tapping a line resumes a paused episode")
        XCTAssertTrue(engine.playing)
        // Landed exactly at the line (minus 1s lead-in), NOT rewound by Smart Resume.
        XCTAssertEqual(pm.positionSeconds, 499, accuracy: 0.5)
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

    func test_endOfItem_noQueue_noOtherUnplayedInShow_closesMiniPlayer() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, guid: "g")
        pm.play(ep)
        engine.emitEnd()
        XCTAssertTrue(ep.played, "episode marked played")
        XCTAssertFalse(pm.isPlaying)
        XCTAssertNil(pm.currentEpisode, "nothing left to play -> mini-player closes")
        XCTAssertEqual(ep.playbackPosition, 0,
                       "closing must not clobber the just-set reset position with a stale tick value")
    }

    // Regression: skip(by:)/seek(toFraction:) used to set positionSeconds directly without ever
    // routing through the played-marking/end-of-episode logic, so landing at the end via the
    // scrubber or the skip-forward button silently did nothing.

    func test_seekToFraction_landingAtEnd_marksPlayed_andAdvances() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g")
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        pm.seek(toFraction: 1.0)   // scrubbing all the way to the end
        XCTAssertTrue(ep1.played, "scrubbing to the end must mark the episode played")
        XCTAssertEqual(pm.currentEpisode?.guid, "g2", "must advance just like a natural finish")
    }

    func test_skipForward_pastEnd_marksPlayed_andAdvances() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g", duration: 100)
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        pm.skip(by: 500)   // skip-forward button (or AirPods next) overshooting the end
        XCTAssertTrue(ep1.played, "skipping past the end must mark the episode played")
        XCTAssertEqual(pm.currentEpisode?.guid, "g2", "must advance just like a natural finish")
    }

    // Regression: an explicit seek must NOT honor outro trim — scrubbing into the outro zone (or a
    // skip landing there) should let the listener hear the final seconds, not auto-advance. Only
    // natural playback ends early at (duration - outro).
    func test_seekIntoOutroZone_doesNotAutoAdvance() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g", duration: 1000, outro: 30)
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        pm.seek(toFraction: 0.99)   // 990s — inside the 30s outro zone, but before the true end
        XCTAssertFalse(ep1.played, "scrubbing into the outro zone must not complete the episode")
        XCTAssertEqual(pm.currentEpisode?.guid, "g", "must stay on the same episode")
    }

    // Natural playback, by contrast, still ends early at (duration - outro) to skip outro music.
    func test_naturalTick_intoOutroZone_stillCompletes() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g", duration: 1000, outro: 30)
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitTime(970)   // reaches (duration - outro) by playing through
        XCTAssertTrue(ep1.played, "natural playback ends early at the outro-trimmed end")
        XCTAssertEqual(pm.currentEpisode?.guid, "g2")
    }

    // Regression: with the default outro trim of 0s, the fallback end-check in handleTimeUpdate
    // used to be gated behind `outro > 0`, so "regular" playback that reaches the end via time
    // ticks (not the native AVPlayerItemDidPlayToEndTime notification) never marked played.
    func test_timeTicksReachingEnd_marksPlayed_evenWithoutNativeEndNotification() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "g", duration: 100)
        let ep2 = makeEpisode(in: ctx, guid: "g2")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitTime(100)   // reaches the true end via a tick; emitEnd() is never called
        XCTAssertTrue(ep1.played)
        XCTAssertEqual(pm.currentEpisode?.guid, "g2")
    }

    func test_endOfItem_noQueue_butAnotherUnplayedInShow_advancesAndStaysOpen() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let pod = Podcast(feedURL: URL(string: "https://ex.com/show.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let s = ShowSettings.makeDefault(); s.podcast = pod; pod.settings = s
        let ep1 = Episode(guid: "e1", title: "E1", publishDate: .now, duration: 100,
                          audioURL: URL(string: "https://ex.com/e1.mp3")!, notes: "")
        let ep2 = Episode(guid: "e2", title: "E2", publishDate: .now.addingTimeInterval(-100), duration: 100,
                          audioURL: URL(string: "https://ex.com/e2.mp3")!, notes: "")
        ep1.podcast = pod; ep2.podcast = pod; pod.episodes = [ep1, ep2]
        ctx.insert(pod); ctx.insert(s); ctx.insert(ep1); ctx.insert(ep2)

        pm.play(ep1)
        engine.emitEnd()
        XCTAssertTrue(ep1.played)
        XCTAssertEqual(pm.currentEpisode?.guid, "e2", "same-show fallback still auto-advances")
        XCTAssertTrue(pm.isPlaying, "mini-player stays open, continuing the show")
    }

    func test_playFromQueue_removesOnlyTappedItem() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        let a = makeEpisode(in: ctx, guid: "a")
        let b = makeEpisode(in: ctx, guid: "b")
        let c = makeEpisode(in: ctx, guid: "c")
        pm.enqueue(a); pm.enqueue(b); pm.enqueue(c)
        pm.playFromQueue(b)
        XCTAssertEqual(pm.currentEpisode?.guid, "b")
        XCTAssertEqual(pm.queue.map(\.guid), ["a", "c"],
                       "skipped-over episodes stay queued — jumping ahead must not silently drop them")
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
        // Regression: the engine must actually be paused, not just the model flag flipped —
        // otherwise (with outro trim) audio plays on to the true end and the native end fires
        // handleEndOfItem a second time, auto-advancing past the armed sleep timer.
        XCTAssertFalse(engine.playing, "engine is paused, not left running")
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

    // Regression: ad detection now caches its AdWindow by episode guid (rebuilding it from
    // ep.chapters on every tick was pure per-tick waste — chapters don't change during playback).
    // Switching to a different episode with its own ad chapter must not reuse the stale window.
    func test_adActive_cachedWindow_invalidatesOnEpisodeSwitch() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "a", duration: 1000)
        let c1 = Chapter(title: "Sponsor", startTime: 100, isAd: true)
        c1.episode = ep1; ep1.chapters.append(c1); ctx.insert(c1)
        let ep2 = makeEpisode(in: ctx, guid: "b", duration: 1000)
        let c2 = Chapter(title: "Sponsor", startTime: 500, isAd: true)
        c2.episode = ep2; ep2.chapters.append(c2); ctx.insert(c2)

        pm.play(ep1)
        engine.emitTime(150)
        XCTAssertTrue(pm.adActive, "inside ep1's ad window")

        pm.play(ep2)
        engine.emitTime(150)
        XCTAssertFalse(pm.adActive, "ep2's ad window starts later — must not reuse ep1's cached window")
        engine.emitTime(550)
        XCTAssertTrue(pm.adActive, "ep2's own ad window is detected correctly")
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
        XCTAssertFalse(engine.playing, "engine is paused, not just the model flag flipped")
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
    // MARK: Retention sweep on natural playback completion

    // Regression: SubscriptionService.setPlayed always swept retention after marking an episode
    // played, but PlaybackManager marking it played itself (finishing IN the player — the most
    // common way an episode finishes) never did, so "delete when finished" silently never fired
    // for that path.
    private func makeRetention(ctx: ModelContext, settings: AppSettings,
                               onDelete: @escaping (Episode) -> Void) -> EpisodeRetentionService {
        EpisodeRetentionService(modelContext: ctx, appSettings: settings, deleteDownload: onDelete)
    }

    func test_handleEndOfItem_sweepsRetentionImmediately() throws {
        let ctx = try makeContext()
        let settings = makeAppSettings()
        settings.defaultAutoDeleteListenedAfterDays = 0   // delete immediately once finished
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: settings)
        let ep = makeEpisode(in: ctx)
        let file = DownloadedFile(localFileName: "x.mp3", fileSizeBytes: 10, downloadedAt: .now)
        file.episode = ep; ep.downloadedFile = file
        ctx.insert(file)

        var deletedGuids: [String] = []
        pm.retention = makeRetention(ctx: ctx, settings: settings) { deletedGuids.append($0.guid) }

        pm.play(ep)
        pm.handleEndOfItem()

        XCTAssertTrue(ep.played)
        XCTAssertEqual(deletedGuids, ["g"],
                       "finishing an episode in the player must sweep retention immediately")
    }

    func test_ninetyFivePercentTick_sweepsRetentionImmediately() throws {
        let ctx = try makeContext()
        let settings = makeAppSettings()
        settings.defaultAutoDeleteListenedAfterDays = 0
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: settings)
        let ep = makeEpisode(in: ctx, duration: 1000)
        let file = DownloadedFile(localFileName: "x.mp3", fileSizeBytes: 10, downloadedAt: .now)
        file.episode = ep; ep.downloadedFile = file
        ctx.insert(file)

        var deletedGuids: [String] = []
        pm.retention = makeRetention(ctx: ctx, settings: settings) { deletedGuids.append($0.guid) }

        pm.play(ep)
        engine.emitTime(960)   // past the 95% mark-played threshold

        XCTAssertTrue(ep.played)
        XCTAssertEqual(deletedGuids, ["g"],
                       "reaching 95% must sweep retention immediately, same as finishing the item")
    }

    // MARK: Audio-session interruptions

    func test_interruption_pausesThenAutoResumesWithHint() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.play(makeEpisode(in: ctx))
        XCTAssertTrue(pm.isPlaying)

        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        XCTAssertFalse(pm.isPlaying, "interruption pauses")
        XCTAssertFalse(engine.playing)

        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
                              optionsRaw: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        XCTAssertTrue(pm.isPlaying, "shouldResume hint auto-resumes, Overcast-style")
        XCTAssertTrue(engine.playing)
    }

    func test_interruptionEnd_withoutResumeHint_stillResumes() throws {
        // Instagram-style interrupters end the interruption WITHOUT the shouldResume hint;
        // we resume anyway — we only paused because they barged in.
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.play(makeEpisode(in: ctx))
        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.ended.rawValue, optionsRaw: 0)
        XCTAssertTrue(pm.isPlaying, "interruption over -> resume even without the hint")
        XCTAssertTrue(engine.playing)
    }

    func test_appBecameActive_afterUnendedInterruption_resumes() throws {
        // Some interrupters never post .ended (session never deactivated). Coming back to the
        // app is the user's "it's over" signal — resume then.
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.play(makeEpisode(in: ctx))
        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        XCTAssertFalse(pm.isPlaying)
        pm.handleAppBecameActive()
        XCTAssertTrue(pm.isPlaying, "foregrounding after an un-ended interruption resumes")
        XCTAssertTrue(engine.playing)
    }

    func test_appBecameActive_withoutPendingInterruption_noops() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.play(makeEpisode(in: ctx))
        pm.togglePlayPause()   // user paused; foregrounding must not restart
        pm.handleAppBecameActive()
        XCTAssertFalse(pm.isPlaying, "plain foregrounding never starts playback")
        XCTAssertFalse(engine.playing)
    }

    func test_interruption_whilePaused_neverResumes() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        pm.play(makeEpisode(in: ctx))
        pm.togglePlayPause()   // user paused before the interruption
        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: nil)
        pm.handleInterruption(typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
                              optionsRaw: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        XCTAssertFalse(pm.isPlaying, "was paused by the user -> an interruption ending must not start playback")
        XCTAssertFalse(engine.playing)
    }

    // MARK: Mini-player dismissal

    func test_dismissPlayer_stopsAndClearsRestore_keepsQueue() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, guid: "dismiss-me")
        let queued = makeEpisode(in: ctx, guid: "queued")
        pm.play(ep)
        pm.enqueue(queued)
        pm.dismissPlayer()
        XCTAssertNil(pm.currentEpisode)
        XCTAssertFalse(pm.isPlaying)
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(pm.queue.map(\.guid), ["queued"], "queue survives a dismissal")
        XCTAssertNil(UserDefaults.standard.string(forKey: PlaybackManager.lastEpisodeKey),
                     "an explicitly closed player must not restore at next launch")
        XCTAssertNil(pm.sleepRemaining)
    }

    func test_play_afterScrollHide_resurfacesMiniPlayer() throws {
        let ctx = try makeContext()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx, appSettings: makeAppSettings())
        pm.miniPlayerHidden = true
        pm.play(makeEpisode(in: ctx))
        XCTAssertFalse(pm.miniPlayerHidden, "starting playback always shows the bar")
    }

}

// MARK: - Clip preview (Clip Review sheet)
extension PlaybackManagerTests {
    func test_previewRange_loopsBackToStart_atEndBound() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 100, end: 130)
        XCTAssertEqual(engine.currentTimeSeconds, 100)
        XCTAssertTrue(pm.isPlaying)
        engine.emitTime(131)
        XCTAssertEqual(engine.currentTimeSeconds, 100, "looped back to the clip start")
        XCTAssertTrue(pm.isPlaying, "still playing after the loop — preview never auto-stops")
    }

    func test_beginClipPreview_pauses_andEndRestoresPositionAndResumes() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        engine.emitTime(500)                    // listener at 500, playing
        pm.beginClipPreview()
        XCTAssertFalse(pm.isPlaying, "sheet open pauses the episode")
        pm.previewRange(episode: ep, start: 100, end: 130)
        engine.emitTime(120)
        pm.endClipPreview()
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.5, "back to the listener's spot")
        XCTAssertEqual(engine.currentTimeSeconds, 500, accuracy: 0.5)
        XCTAssertTrue(pm.isPlaying, "was playing before the sheet → resumes")
    }

    func test_endClipPreview_staysPaused_whenListenerWasPaused() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        engine.emitTime(500)
        pm.togglePlayPause()                    // paused at 500
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 100, end: 130)
        pm.endClipPreview()
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.5)
        XCTAssertFalse(pm.isPlaying, "was paused before the sheet → stays paused")
    }

    func test_previewRange_differentEpisode_loadsIt_andEndRestoresOriginal() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let listening = makeEpisode(in: ctx, guid: "listening")
        let clipOwner = makeEpisode(in: ctx, guid: "clip-owner")
        var downloaded: [String] = []
        pm.ensureDownloaded = { downloaded.append($0.guid) }
        pm.play(listening)
        engine.emitTime(500)
        pm.beginClipPreview()
        pm.previewRange(episode: clipOwner, start: 40, end: 60)
        XCTAssertEqual(pm.currentEpisode?.guid, "clip-owner")
        XCTAssertEqual(engine.loadedURL, clipOwner.audioURL)
        XCTAssertEqual(engine.currentTimeSeconds, 40)
        XCTAssertFalse(downloaded.contains("clip-owner"),
                       "preview must not auto-download the clip's episode")
        pm.endClipPreview()
        XCTAssertEqual(pm.currentEpisode?.guid, "listening", "original episode restored")
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.5)
        XCTAssertTrue(pm.isPlaying)
    }

    func test_previewTicks_doNotPersistPosition_orMarkPlayed() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        engine.emitTime(500)                    // persists 500
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 950, end: 990)
        engine.emitTime(960)                    // >95% — must NOT mark played
        XCTAssertFalse(ep.played, "preview past 95% never marks the episode played")
        XCTAssertEqual(ep.playbackPosition, 500, accuracy: 0.5,
                       "preview ticks never persist position")
    }

    func test_manualSkip_cancelsPreviewLoop() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 100, end: 130)
        pm.skip(by: 200)                        // user takes over via transport
        engine.emitTime(331)
        XCTAssertEqual(engine.currentTimeSeconds, 331, accuracy: 0.5,
                       "no loop-back once the user seeks manually")
    }

    func test_silenceSkip_doesNotFireDuringPreview() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        ep.podcast?.settings?.skipSilence = true
        pm.play(ep)
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 100, end: 130)
        for _ in 0..<10 { engine.onRMS?(0.001, 0.1) }   // sustained silence
        XCTAssertEqual(engine.currentTimeSeconds, 100, accuracy: 0.5,
                       "no silence skip while previewing")
        engine.emitTime(131)
        XCTAssertEqual(engine.currentTimeSeconds, 100, accuracy: 0.5,
                       "preview loop still intact")
    }

    func test_beginClipPreview_secondCallKeepsOriginalSnapshot() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        engine.emitTime(500)                    // playing at 500
        pm.beginClipPreview()
        pm.beginClipPreview()                   // e.g. onAppear firing twice
        pm.previewRange(episode: ep, start: 100, end: 130)
        pm.endClipPreview()
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.5)
        XCTAssertTrue(pm.isPlaying, "original wasPlaying=true snapshot survives the double begin")
    }

    func test_stopPreviewPlayback_pausesAndKeepsPlayhead() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep = makeEpisode(in: ctx, duration: 1000)
        pm.play(ep)
        pm.beginClipPreview()
        pm.previewRange(episode: ep, start: 100, end: 130)
        engine.emitTime(115)
        pm.stopPreviewPlayback()
        XCTAssertFalse(pm.isPlaying)
        XCTAssertEqual(pm.positionSeconds, 115, accuracy: 0.5,
                       "playhead stays where preview stopped (used by Set to playhead)")
        engine.emitTime(131)
        XCTAssertEqual(engine.currentTimeSeconds, 131, accuracy: 0.5, "loop cleared by stop")
    }

    func test_nativeEndOfItem_duringPreview_loopsAndPreservesState() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        let ep1 = makeEpisode(in: ctx, guid: "listening", duration: 1000)
        let ep2 = makeEpisode(in: ctx, guid: "queued")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitTime(500)
        pm.beginClipPreview()
        pm.previewRange(episode: ep1, start: 900, end: 1000)   // range ends at the true episode end
        engine.emitEnd()                                       // native end-of-item fires during preview
        XCTAssertFalse(ep1.played, "preview reaching media end must not mark the episode played")
        XCTAssertEqual(pm.queue.count, 1, "a preview must not consume a queue item")
        XCTAssertEqual(engine.currentTimeSeconds, 900, accuracy: 0.5, "preview loops back to range start")
    }
}
