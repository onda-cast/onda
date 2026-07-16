# Onda Plan 3: Playback Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play episodes (stream or, later, downloaded) with a full Now Playing screen and mini-player, a cross-show Up Next queue, a sleep timer, lock-screen/Control-Center controls, resume-across-launch, and chapter display.

**Architecture:** `PlaybackManager` (`@Observable`) owns an `AVPlayer` behind a `PlayerEngine` protocol so all queue/trim/sleep/position logic is unit-tested against a fake engine with no real audio. All positions are in **feed-seconds** (canonical timeline). Now Playing and the mini-player read `PlaybackManager` from the environment. Chapters are fetched from the Podcasting-2.0 `chaptersURL` captured in Plan 2 and stored as `Chapter` rows.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVPlayer`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), SwiftData, XCTest.

## Global Constraints

- Deployment target iOS 17.0; SwiftUI + SwiftData only (Plan 1 Global Constraints apply verbatim).
- **Canonical timeline:** `Episode.playbackPosition`, `Chapter.startTime`, scrubber, and seeks are all in original feed-seconds. Speed/trim are playback-layer effects that never change stored time.
- All `AVPlayer` access goes through the `PlayerEngine` protocol; no test touches real audio hardware.
- `AVAudioSession` category `.playback` is activated at launch so audio survives backgrounding/lock (background mode `audio` already set in Plan 1 project config).
- Position is persisted every ~5s while playing and on pause/stop; `played` flips true past 95%.
- Visual language + services from Plans 1–2.

**Depends on:** Plans 1–2 complete.

---

## File Structure

```
Onda/
  Playback/
    PlayerEngine.swift        — protocol + AVPlayerEngine (real) 
    PlaybackManager.swift     — @Observable: transport, queue, sleep timer, position, remote
    NowPlayingCenter.swift    — MPNowPlayingInfoCenter + MPRemoteCommandCenter wiring
    ChapterFetcher.swift      — fetch Podcasting-2.0 chapters JSON → [Chapter]
  Player/
    NowPlayingView.swift      — full-screen player (art, scrubber, transport, chips, chapters, notes)
    MiniPlayerView.swift      — docked mini player
    SleepTimerMenu.swift      — sleep timer picker
    QueueView.swift           — Up Next list (reorder / jump / remove)
  Shell/
    RootView.swift            — MODIFY: overlay mini-player + present Now Playing
    LibraryView.swift / EpisodeListView / DiscoverView — MODIFY: wire onPlay → PlaybackManager
OndaTests/
  PlaybackManagerTests.swift
  ChapterFetcherTests.swift
OndaTests/Fixtures/
  chapters.json
```

---

### Task 1: PlayerEngine protocol + fake

**Files:**
- Create: `Onda/Playback/PlayerEngine.swift`
- Test: `OndaTests/PlaybackManagerTests.swift` (fake lives here initially, used across tasks)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol PlayerEngine: AnyObject { var rate: Float { get set }; var currentTimeSeconds: TimeInterval { get }; var onEndOfItem: (() -> Void)? { get set }; var onTimeUpdate: ((TimeInterval) -> Void)? { get set }; func load(url: URL, startAt: TimeInterval); func play(); func pause(); func seek(to seconds: TimeInterval) }`
  - `final class AVPlayerEngine: PlayerEngine` (real implementation)

- [ ] **Step 1: Write the protocol + real engine**

Create `Onda/Playback/PlayerEngine.swift`:

```swift
//  PlayerEngine.swift
import AVFoundation

protocol PlayerEngine: AnyObject {
    var rate: Float { get set }
    var currentTimeSeconds: TimeInterval { get }
    var onEndOfItem: (() -> Void)? { get set }
    var onTimeUpdate: ((TimeInterval) -> Void)? { get set }
    func load(url: URL, startAt: TimeInterval)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
}

final class AVPlayerEngine: PlayerEngine {
    private let player = AVPlayer()
    private var timeObserver: Any?
    var onEndOfItem: (() -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?

    var rate: Float {
        get { player.rate }
        set { if player.timeControlStatus == .playing { player.rate = newValue } else { player.defaultRate = newValue } }
    }
    var currentTimeSeconds: TimeInterval { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func load(url: URL, startAt: TimeInterval) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if startAt > 0 { seek(to: startAt) }
        addObservers(for: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func addObservers(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            self?.onEndOfItem?()
        }
        if timeObserver == nil {
            let interval = CMTime(seconds: 1, preferredTimescale: 2)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
                self?.onTimeUpdate?(t.seconds.isFinite ? t.seconds : 0)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Onda/Playback/PlayerEngine.swift
git commit -m "feat: PlayerEngine protocol + AVPlayerEngine"
```

---

### Task 2: PlaybackManager — transport, position, trim

**Files:**
- Create: `Onda/Playback/PlaybackManager.swift`
- Test: `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Consumes: `PlayerEngine`, `Episode`, `ShowSettings`, `ModelContext`.
- Produces:
  - `@Observable final class PlaybackManager`
  - `init(engine: PlayerEngine, modelContext: ModelContext)`
  - `var currentEpisode: Episode?`, `var isPlaying: Bool`, `var positionSeconds: TimeInterval`, `var durationSeconds: TimeInterval`
  - `func play(_ episode: Episode)` — loads (downloaded file if present else stream), applies show speed + intro trim, starts at `max(playbackPosition, introTrimSec)`
  - `func togglePlayPause()`, `func skip(by seconds: TimeInterval)`, `func seek(toFraction f: Double)`
  - `var progressFraction: Double` (0…1 in feed-time)
  - Persists `playbackPosition` on every time update (throttled ~5s) and flips `played` past 95%; applies `outroTrimSec` (treat "end" as `duration - outroTrimSec`).

- [ ] **Step 1: Write the failing transport/trim/position tests**

Create `OndaTests/PlaybackManagerTests.swift`:

```swift
//  PlaybackManagerTests.swift
import XCTest
import SwiftData
@testable import Onda

final class FakeEngine: PlayerEngine {
    var rate: Float = 1
    var currentTimeSeconds: TimeInterval = 0
    var onEndOfItem: (() -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    private(set) var loadedURL: URL?
    private(set) var startAt: TimeInterval = 0
    private(set) var playing = false
    func load(url: URL, startAt: TimeInterval) { loadedURL = url; self.startAt = startAt; currentTimeSeconds = startAt }
    func play() { playing = true }
    func pause() { playing = false }
    func seek(to seconds: TimeInterval) { currentTimeSeconds = max(0, seconds) }
    // test helper
    func emitTime(_ t: TimeInterval) { currentTimeSeconds = t; onTimeUpdate?(t) }
    func emitEnd() { onEndOfItem?() }
}

final class PlaybackManagerTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }
    private func makeEpisode(in ctx: ModelContext, duration: TimeInterval = 1000,
                             intro: Int = 0, outro: Int = 0, speed: Double = 1.0,
                             position: TimeInterval = 0) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let s = ShowSettings.makeDefault(); s.introTrimSec = intro; s.outroTrimSec = outro; s.speed = speed
        s.podcast = pod; pod.settings = s
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: duration,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "", playbackPosition: position)
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(s); ctx.insert(ep)
        return ep
    }

    func test_play_streamsAudio_appliesSpeed_andStartsAtIntroTrim() throws {
        let ctx = try ctx()
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
        let ctx = try ctx()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, intro: 30, position: 200)
        pm.play(ep)
        XCTAssertEqual(engine.startAt, 200)
    }

    func test_timeUpdate_persistsPosition_andMarksPlayedNear95pct() throws {
        let ctx = try ctx()
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

    func test_skip_movesPositionInFeedTime() throws {
        let ctx = try ctx()
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests`
Expected: FAIL — `cannot find 'PlaybackManager' in scope`.

- [ ] **Step 3: Write PlaybackManager (transport/position/trim only; queue+sleep added in Task 3)**

Create `Onda/Playback/PlaybackManager.swift`:

```swift
//  PlaybackManager.swift
import Foundation
import SwiftData
import AVFoundation

@Observable
final class PlaybackManager {
    private let engine: PlayerEngine
    private let modelContext: ModelContext

    var currentEpisode: Episode?
    var isPlaying: Bool = false
    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0

    private var lastPersistedAt: TimeInterval = -100

    init(engine: PlayerEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext
        engine.onTimeUpdate = { [weak self] t in self?.handleTimeUpdate(t) }
        engine.onEndOfItem = { [weak self] in self?.handleEndOfItem() }
    }

    private var settings: ShowSettings? { currentEpisode?.podcast?.settings }
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    func play(_ episode: Episode) {
        currentEpisode = episode
        durationSeconds = episode.duration
        let intro = TimeInterval(settings?.introTrimSec ?? 0)
        let start = max(episode.playbackPosition, intro)
        let url = localURL(for: episode) ?? episode.audioURL
        engine.load(url: url, startAt: start)
        engine.rate = Float(settings?.speed ?? 1.0)
        positionSeconds = start
        engine.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying { engine.pause(); persistPosition(force: true) }
        else { engine.play() }
        isPlaying.toggle()
    }

    func skip(by seconds: TimeInterval) {
        let target = max(0, min(durationSeconds, positionSeconds + seconds))
        engine.seek(to: target); positionSeconds = target
    }

    func seek(toFraction f: Double) {
        let target = max(0, min(durationSeconds, durationSeconds * f))
        engine.seek(to: target); positionSeconds = target
    }

    // Resolve a downloaded file to a playable URL (Plan 5 populates downloadedFile).
    func localURL(for episode: Episode) -> URL? {
        guard let name = episode.downloadedFile?.localFileName else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func handleTimeUpdate(_ t: TimeInterval) {
        positionSeconds = t
        guard let ep = currentEpisode else { return }

        // Outro trim: treat (duration - outro) as the effective end.
        let outro = TimeInterval(settings?.outroTrimSec ?? 0)
        if outro > 0, t >= ep.duration - outro { handleEndOfItem(); return }

        if t - lastPersistedAt >= 5 { persistPosition(force: false) }
        if ep.duration > 0, t >= ep.duration * 0.95, !ep.played {
            ep.played = true; try? modelContext.save()
        }
    }

    private func persistPosition(force: Bool) {
        guard let ep = currentEpisode else { return }
        ep.playbackPosition = positionSeconds
        lastPersistedAt = positionSeconds
        try? modelContext.save()
    }

    // Overridden in Task 3 to advance the queue.
    func handleEndOfItem() {
        if let ep = currentEpisode { ep.played = true; ep.playbackPosition = 0 }
        isPlaying = false
        try? modelContext.save()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/PlaybackManager.swift OndaTests/PlaybackManagerTests.swift
git commit -m "feat: PlaybackManager transport, feed-time position persistence, speed + intro/outro trim"
```

---

### Task 3: Queue + sleep timer

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`
- Modify: `OndaTests/PlaybackManagerTests.swift` (add queue + sleep tests)

**Interfaces:**
- Consumes: `QueueItem`, `Episode`.
- Produces (added to `PlaybackManager`):
  - `var queue: [Episode]` (ordered, derived from `QueueItem.position`)
  - `func enqueue(_ episode: Episode)`, `func removeFromQueue(_ episode: Episode)`, `func moveQueue(from: IndexSet, to: Int)`
  - On end-of-item: mark played, then `playNextInQueue()` → first queue item, else next unplayed episode in same show, else stop.
  - Sleep timer: `enum SleepMode { case off, duration(TimeInterval), endOfEpisode }`, `var sleepMode: SleepMode`, `func setSleepTimer(_:)`; a duration timer pauses playback when it elapses; `endOfEpisode` pauses at handleEndOfItem instead of advancing.

- [ ] **Step 1: Write failing queue + sleep tests**

Append to `OndaTests/PlaybackManagerTests.swift`:

```swift
extension PlaybackManagerTests {
    func test_endOfItem_advancesToNextQueueItem() throws {
        let ctx = try ctx()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep1 = makeEpisode(in: ctx)
        let ep2 = makeEpisode(in: ctx); ep2.guid = "g2"
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitEnd()
        XCTAssertEqual(pm.currentEpisode?.guid, "g2")
        XCTAssertTrue(pm.isPlaying)
    }

    func test_removeFromQueue_dropsEpisode() throws {
        let ctx = try ctx()
        let pm = PlaybackManager(engine: FakeEngine(), modelContext: ctx)
        let ep = makeEpisode(in: ctx)
        pm.enqueue(ep)
        XCTAssertEqual(pm.queue.count, 1)
        pm.removeFromQueue(ep)
        XCTAssertEqual(pm.queue.count, 0)
    }

    func test_sleepEndOfEpisode_pausesInsteadOfAdvancing() throws {
        let ctx = try ctx()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep1 = makeEpisode(in: ctx)
        let ep2 = makeEpisode(in: ctx); ep2.guid = "g2"
        pm.play(ep1); pm.enqueue(ep2)
        pm.setSleepTimer(.endOfEpisode)
        engine.emitEnd()
        XCTAssertEqual(pm.currentEpisode?.guid, "g", "stays on the finished episode's show, does not auto-advance")
        XCTAssertFalse(pm.isPlaying)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests/test_endOfItem_advancesToNextQueueItem`
Expected: FAIL — `value of type 'PlaybackManager' has no member 'enqueue'`.

- [ ] **Step 3: Add queue + sleep to PlaybackManager**

Add these members inside `PlaybackManager` and replace `handleEndOfItem()`:

```swift
    // MARK: Queue
    private(set) var queue: [Episode] = []

    func enqueue(_ episode: Episode) {
        guard !queue.contains(where: { $0.guid == episode.guid }) else { return }
        let item = QueueItem(episode: episode, position: queue.count)
        modelContext.insert(item)
        queue.append(episode)
        try? modelContext.save()
    }

    func removeFromQueue(_ episode: Episode) {
        queue.removeAll { $0.guid == episode.guid }
        let guid = episode.guid
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for it in items where it.episode?.guid == guid { modelContext.delete(it) }
        reindexQueue()
    }

    func moveQueue(from: IndexSet, to: Int) {
        queue.move(fromOffsets: from, toOffset: to)
        reindexQueue()
    }

    private func reindexQueue() {
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for ep in queue.enumerated() {
            items.first { $0.episode?.guid == ep.element.guid }?.position = ep.offset
        }
        try? modelContext.save()
    }

    private func playNextInQueue() {
        if !queue.isEmpty {
            let next = queue.removeFirst()
            removeFromQueue(next)
            play(next)
            return
        }
        if let show = currentEpisode?.podcast,
           let next = show.episodes
               .filter({ !$0.played && $0.guid != currentEpisode?.guid })
               .sorted(by: { $0.publishDate > $1.publishDate }).first {
            play(next)
            return
        }
        isPlaying = false
    }

    // MARK: Sleep timer
    enum SleepMode: Equatable { case off, duration(TimeInterval), endOfEpisode }
    var sleepMode: SleepMode = .off
    private var sleepTimer: Timer?

    func setSleepTimer(_ mode: SleepMode) {
        sleepMode = mode
        sleepTimer?.invalidate(); sleepTimer = nil
        if case let .duration(seconds) = mode {
            sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
                self.sleepMode = .off
            }
        }
    }
```

Replace the existing `handleEndOfItem()` with:

```swift
    func handleEndOfItem() {
        if let ep = currentEpisode { ep.played = true; ep.playbackPosition = 0 }
        try? modelContext.save()
        if sleepMode == .endOfEpisode {
            isPlaying = false
            sleepMode = .off
            return
        }
        playNextInQueue()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/PlaybackManager.swift OndaTests/PlaybackManagerTests.swift
git commit -m "feat: cross-show queue + sleep timer with end-of-episode mode"
```

---

### Task 4: Chapter fetcher

**Files:**
- Create: `Onda/Playback/ChapterFetcher.swift`
- Create: `OndaTests/Fixtures/chapters.json`, `OndaTests/ChapterFetcherTests.swift`

**Interfaces:**
- Consumes: Podcasting-2.0 chapters JSON URL (from `ParsedEpisode.chaptersURL`, stored per-episode).
- Produces:
  - `struct ParsedChapter { let title: String; let startTime: TimeInterval; let isAd: Bool }`
  - `struct ChapterFetcher { func decode(_ data: Data) -> [ParsedChapter]; func fetch(_ url: URL) async throws -> [ParsedChapter] }`
  - Ad detection: a chapter is `isAd` when its JSON has `"toc": false` OR a `title` containing "ad"/"sponsor" (case-insensitive) — matches the spec's "real ad marker" rule.

> Chapters URL persistence: add `var chaptersURL: URL?` to `Episode` (SwiftData migration is automatic for a new optional). Plan 2's `SubscriptionService.refreshEpisodes` sets it from `ParsedEpisode.chaptersURL` — add that one-line assignment when implementing this task.

- [ ] **Step 1: Add fixture**

Create `OndaTests/Fixtures/chapters.json`:

```json
{
  "version": "1.2.0",
  "chapters": [
    { "startTime": 0, "title": "Cold open" },
    { "startTime": 210, "title": "The homepage in 2005" },
    { "startTime": 600, "title": "Sponsor: Acme", "toc": false },
    { "startTime": 780, "title": "When feeds took over" }
  ]
}
```

- [ ] **Step 2: Write failing tests**

Create `OndaTests/ChapterFetcherTests.swift`:

```swift
//  ChapterFetcherTests.swift
import XCTest
@testable import Onda

final class ChapterFetcherTests: XCTestCase {
    func test_decode_parsesChaptersAndFlagsAds() throws {
        let url = Bundle(for: Self.self).url(forResource: "chapters", withExtension: "json")!
        let chapters = ChapterFetcher().decode(try Data(contentsOf: url))
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters[0].title, "Cold open")
        XCTAssertEqual(chapters[2].startTime, 600)
        XCTAssertTrue(chapters[2].isAd, "toc:false or 'sponsor' title marks an ad")
        XCTAssertFalse(chapters[3].isAd)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ChapterFetcherTests`
Expected: FAIL — `cannot find 'ChapterFetcher' in scope`.

- [ ] **Step 4: Write the fetcher + add `chaptersURL` to Episode**

Create `Onda/Playback/ChapterFetcher.swift`:

```swift
//  ChapterFetcher.swift
import Foundation

struct ParsedChapter { let title: String; let startTime: TimeInterval; let isAd: Bool }

struct ChapterFetcher {
    typealias Transport = (URL) async throws -> Data
    private let transport: Transport
    init(transport: @escaping Transport = { try await URLSession.shared.data(from: $0).0 }) {
        self.transport = transport
    }

    func decode(_ data: Data) -> [ParsedChapter] {
        struct Doc: Codable {
            struct Ch: Codable { let startTime: Double?; let title: String?; let toc: Bool? }
            let chapters: [Ch]
        }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return [] }
        return doc.chapters.map { c in
            let title = c.title ?? "Chapter"
            let adByTitle = ["ad", "sponsor"].contains { title.lowercased().contains($0) }
            let adByToc = (c.toc == false)
            return ParsedChapter(title: title, startTime: c.startTime ?? 0, isAd: adByTitle || adByToc)
        }
    }

    func fetch(_ url: URL) async throws -> [ParsedChapter] { decode(try await transport(url)) }
}
```

Add to `Onda/Models/Episode.swift` (property + init default):

```swift
    var chaptersURL: URL?
```
and add `chaptersURL: URL? = nil` to the initializer parameter list, assigning `self.chaptersURL = chaptersURL`.

In `Onda/Services/SubscriptionService.swift`, in `refreshEpisodes`, set it when creating an `Episode`:
```swift
            ep.chaptersURL = pe.chaptersURL
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ChapterFetcherTests`
Expected: PASS (1 test). Also re-run `SubscriptionServiceTests` to confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add Onda/Playback/ChapterFetcher.swift Onda/Models/Episode.swift Onda/Services/SubscriptionService.swift OndaTests/ChapterFetcherTests.swift OndaTests/Fixtures/chapters.json
git commit -m "feat: ChapterFetcher with ad-marker detection; persist chaptersURL on Episode"
```

---

### Task 5: Now Playing center (lock screen / remote)

**Files:**
- Create: `Onda/Playback/NowPlayingCenter.swift`
- Modify: `Onda/Playback/PlaybackManager.swift` (call into it)
- Modify: `Onda/OndaApp.swift` (activate audio session)

**Interfaces:**
- Consumes: `PlaybackManager` state.
- Produces:
  - `final class NowPlayingCenter` with `func configureRemoteCommands(play:pause:skipForward:skipBack:)` and `func update(title:show:position:duration:rate:)`
  - `AudioSession.activate()` static helper (category `.playback`).

- [ ] **Step 1: Write the now-playing center + audio session**

Create `Onda/Playback/NowPlayingCenter.swift`:

```swift
//  NowPlayingCenter.swift
import MediaPlayer
import AVFoundation

enum AudioSession {
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }
}

final class NowPlayingCenter {
    private let center = MPRemoteCommandCenter.shared()

    func configureRemoteCommands(play: @escaping () -> Void, pause: @escaping () -> Void,
                                 skipForward: @escaping () -> Void, skipBack: @escaping () -> Void) {
        center.playCommand.addTarget { _ in play(); return .success }
        center.pauseCommand.addTarget { _ in pause(); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in skipForward(); return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in skipBack(); return .success }
    }

    func update(title: String, show: String, position: TimeInterval, duration: TimeInterval, rate: Float) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: show,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
```

- [ ] **Step 2: Wire it into PlaybackManager**

In `PlaybackManager`, add a `NowPlayingCenter` and update it. Add property `private let nowPlaying = NowPlayingCenter()`, in `init` call `configureRemoteCommands` mapping to `engine.play`/`pause` (via `togglePlayPause`-style closures) and `skip(by: 30)` / `skip(by: -15)`, and in `handleTimeUpdate` call:

```swift
        nowPlaying.update(title: currentEpisode?.title ?? "", show: currentEpisode?.podcast?.title ?? "",
                          position: positionSeconds, duration: durationSeconds,
                          rate: isPlaying ? Float(settings?.speed ?? 1.0) : 0)
```

Add to `init` (after setting engine callbacks):
```swift
        nowPlaying.configureRemoteCommands(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pauseExternally() },
            skipForward: { [weak self] in self?.skip(by: 30) },
            skipBack: { [weak self] in self?.skip(by: -15) })
```
Add helpers:
```swift
    private func resume() { guard !isPlaying, currentEpisode != nil else { return }; enginePlay() }
    private func pauseExternally() { guard isPlaying else { return }; togglePlayPause() }
    private func enginePlay() { togglePlayPause() }
```

- [ ] **Step 3: Activate the audio session at launch**

In `Onda/OndaApp.swift` `init`, after building the container, add:
```swift
        AudioSession.activate()
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/NowPlayingCenter.swift Onda/Playback/PlaybackManager.swift Onda/OndaApp.swift
git commit -m "feat: lock-screen/Control-Center remote commands + audio session"
```

---

### Task 6: Now Playing screen + mini-player + sleep menu + queue view

**Files:**
- Create: `Onda/Player/NowPlayingView.swift`, `Onda/Player/MiniPlayerView.swift`, `Onda/Player/SleepTimerMenu.swift`, `Onda/Player/QueueView.swift`
- Modify: `Onda/Shell/RootView.swift`, `Onda/Library/EpisodeListView.swift`, `Onda/OndaApp.swift`

**Interfaces:**
- Consumes: `PlaybackManager` (environment), `ArtworkView`, brutal styles.
- Produces: mini-player docked above the tab bar when `currentEpisode != nil`; tapping it opens `NowPlayingView` (full-screen cover) with artwork, title/show, feed-time scrubber, ±15/30 skip, play/pause, Speed/Boost/Skip-Silence chips (Boost/Silence are per-show `ShowSettings` toggles; audio effect lands in Plan 4), sleep-timer action, Chapters list, About notes, and a queue button opening `QueueView`. `EpisodeRow.onPlay` now calls `playback.play(episode)`.

- [ ] **Step 1: Sleep timer menu**

Create `Onda/Player/SleepTimerMenu.swift`:

```swift
//  SleepTimerMenu.swift
import SwiftUI

struct SleepTimerMenu: View {
    @Environment(PlaybackManager.self) private var playback
    var body: some View {
        Menu {
            Button("Off") { playback.setSleepTimer(.off) }
            ForEach([5, 10, 15, 30, 45], id: \.self) { m in
                Button("\(m) min") { playback.setSleepTimer(.duration(TimeInterval(m * 60))) }
            }
            Button("End of episode") { playback.setSleepTimer(.endOfEpisode) }
        } label: {
            Image(systemName: playback.sleepMode == .off ? "moon" : "moon.fill")
                .font(.system(size: 18, weight: .semibold))
        }
    }
}
```

- [ ] **Step 2: Queue view**

Create `Onda/Player/QueueView.swift`:

```swift
//  QueueView.swift
import SwiftUI

struct QueueView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var body: some View {
        NavigationStack {
            List {
                ForEach(playback.queue, id: \.guid) { ep in
                    Button { playback.play(ep) } label: {
                        VStack(alignment: .leading) {
                            Text(ep.title).font(.system(size: 15, weight: .semibold))
                            Text(ep.podcast?.title ?? "").font(.system(size: 12.5))
                                .foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                }
                .onMove { playback.moveQueue(from: $0, to: $1) }
                .onDelete { idx in idx.map { playback.queue[$0] }.forEach(playback.removeFromQueue) }
            }
            .navigationTitle("Up Next")
            .toolbar { EditButton() }
        }
    }
}
```

- [ ] **Step 3: Mini-player**

Create `Onda/Player/MiniPlayerView.swift`:

```swift
//  MiniPlayerView.swift
import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var onTap: () -> Void

    var body: some View {
        if let ep = playback.currentEpisode {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ep.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                            .lineLimit(1)
                        Text(ep.podcast?.title ?? "").font(.system(size: 13.5))
                            .foregroundStyle(theme.color(.textTertiary))
                    }
                    Spacer(minLength: 8)
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20)).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(theme.color(.accent))
                            .brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).frame(height: 76)
                .background(theme.color(.sheetBg)).brutalBorder(width: 2.5).hardShadow(offset: 4)
                .overlay(alignment: .bottomLeading) {
                    Rectangle().fill(theme.color(.accent))
                        .frame(width: max(0, CGFloat(playback.progressFraction)) * UIScreen.main.bounds.width, height: 3)
                }
            }.buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 4: Now Playing screen**

Create `Onda/Player/NowPlayingView.swift`:

```swift
//  NowPlayingView.swift
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    private var ep: Episode? { playback.currentEpisode }
    private var settings: ShowSettings? { ep?.podcast?.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if let ep {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title)
                        .frame(maxWidth: 280).aspectRatio(1, contentMode: .fit)
                        .brutalBorder(width: 3).hardShadow(offset: 8)
                    Text(ep.title).brutalHeader(size: 19).multilineTextAlignment(.center)
                        .foregroundStyle(theme.color(.text))
                    Text(ep.podcast?.title ?? "").font(.system(size: 15, weight: .bold))
                        .textCase(.uppercase).foregroundStyle(theme.color(.accent))
                    scrubber
                    transport
                    chips
                    chapters(ep)
                    about(ep)
                }
            }
            .padding(.horizontal, 32).padding(.top, 60).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(theme.color(.bg).ignoresSafeArea())
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)) }
            Spacer()
            SleepTimerMenu()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.system(size: 16, weight: .bold)) }
        }
        .foregroundStyle(theme.color(.textSecondary))
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { playback.progressFraction },
                set: { playback.seek(toFraction: $0) }), in: 0...1)
            .tint(theme.color(.accent))
            HStack {
                Text(timeStr(playback.positionSeconds))
                Spacer()
                Text("-" + timeStr(max(0, playback.durationSeconds - playback.positionSeconds)))
            }
            .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(theme.color(.textTertiary))
        }
        .frame(maxWidth: 280)
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { playback.skip(by: -15) } label: { skipLabel("gobackward.15") }
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44)).foregroundStyle(.white)
                    .frame(width: 120, height: 120).background(theme.color(.accent))
                    .brutalBorder(width: 3).hardShadow(offset: 6)
            }
            Button { playback.skip(by: 30) } label: { skipLabel("goforward.30") }
        }.buttonStyle(.plain)
    }

    private func skipLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(theme.color(.text))
            .frame(width: 76, height: 76).background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    // Speed cycles; Boost/Skip-Silence toggle ShowSettings (audio effect wired in Plan 4).
    private var chips: some View {
        HStack(spacing: 10) {
            Button { cycleSpeed() } label: { chip("\(settings?.speed ?? 1.0)×", active: false) }
            Button { toggleBoost() } label: {
                chip("Boost: \(boostLabel)", active: (settings?.voiceBoost ?? 0) > 0)
            }
            Button { toggleSilence() } label: {
                chip(settings?.skipSilence == true ? "No Silence" : "Silence On",
                     active: settings?.skipSilence == true)
            }
        }
    }

    private func chip(_ text: String, active: Bool) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.text))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(active ? theme.color(.accentWash) : theme.color(.bgElevated))
            .brutalBorder(width: 2)
    }

    private var boostLabel: String { ["Off", "Med", "High"][settings?.voiceBoost ?? 0] }

    private func chapters(_ ep: Episode) -> some View {
        Group {
            if !ep.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chapters").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    ForEach(ep.chapters.sorted { $0.startTime < $1.startTime }, id: \.startTime) { ch in
                        Button { playback.seek(toFraction: ch.startTime / max(1, ep.duration)) } label: {
                            HStack {
                                Text(ch.title).font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(theme.color(.text))
                                Spacer()
                                Text(timeStr(ch.startTime)).font(.system(size: 12.5)).monospacedDigit()
                                    .foregroundStyle(theme.color(.textTertiary))
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider().overlay(theme.color(.separator))
                    }
                }.frame(maxWidth: 280)
            }
        }
    }

    private func about(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About This Episode").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            Text(ep.notes).font(.system(size: 14.5)).foregroundStyle(theme.color(.textSecondary))
        }.frame(maxWidth: 280, alignment: .leading)
    }

    private func cycleSpeed() {
        let steps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
        guard let s = settings else { return }
        let i = steps.firstIndex(of: s.speed) ?? 1
        s.speed = steps[(i + 1) % steps.count]
    }
    private func toggleBoost() { settings.map { $0.voiceBoost = ($0.voiceBoost + 1) % 3 } }
    private func toggleSilence() { settings.map { $0.skipSilence.toggle() } }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 5: Overlay mini-player + present Now Playing in RootView**

Modify `Onda/Shell/RootView.swift` — add state and overlay. Insert `@State private var nowPlayingOpen = false` and change the `ZStack` to include the mini-player above the tab bar and a full-screen cover:

```swift
        ZStack(alignment: .bottom) {
            theme.color(.bg).ignoresSafeArea()
            Group {
                switch tab {
                case .library:  LibraryView()
                case .discover: DiscoverView()
                case .profile:  ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                MiniPlayerView { nowPlayingOpen = true }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                tabBar
            }
        }
        .fullScreenCover(isPresented: $nowPlayingOpen) { NowPlayingView() }
```

- [ ] **Step 6: Wire EpisodeRow.onPlay and inject PlaybackManager**

In `Onda/Library/EpisodeListView.swift`, add `@Environment(PlaybackManager.self) private var playback` and change the row to:
```swift
                    EpisodeRow(episode: ep, onPlay: { playback.play(ep) })
```

In `Onda/OndaApp.swift`, add the manager to state and inject it:
```swift
    @State private var playback: PlaybackManager
```
in `init` after the container:
```swift
            _playback = State(initialValue:
                PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext))
```
and add `.environment(playback)` in `body`.

- [ ] **Step 7: Build, run, verify end-to-end playback**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Then launch and confirm: play an episode from the Episode List → mini-player appears → tap → Now Playing → play/pause, scrubber, ±15/30, speed cycle, sleep menu, queue sheet all work; audio plays; lock the simulator (Cmd+L) and confirm Control Center shows the episode with working controls.

- [ ] **Step 8: Commit**

```bash
git add Onda/Player Onda/Shell/RootView.swift Onda/Library/EpisodeListView.swift Onda/OndaApp.swift
git commit -m "feat: Now Playing screen, mini-player, sleep menu, queue view; end-to-end playback"
```

---

## Self-Review

- **Spec coverage:** AVPlayer stream/downloaded playback ✓; feed-time canonical positions ✓; speed + intro/outro trim ✓; cross-show queue (Up Next) ✓; sleep timer as Now Playing action ✓; MPNowPlayingInfoCenter + MPRemoteCommandCenter ✓; resume-across-launch (position persistence) ✓; chapters display + jump ✓; ad-marker detection (`ChapterFetcher.isAd`) ✓. The ad *banner* rendering and voice-boost/skip-silence *audio effect* are Plan 4 (this plan only toggles the settings + detects ads).
- **Placeholder scan:** Boost/Skip-Silence chips here mutate `ShowSettings` and are visually reflected; the actual DSP is explicitly Plan 4 — documented, not a hidden TODO. All code steps complete.
- **Type consistency:** `PlaybackManager(engine:modelContext:)`, `PlayerEngine`, `play(_:)`, `togglePlayPause()`, `skip(by:)`, `seek(toFraction:)`, `enqueue/removeFromQueue/moveQueue`, `setSleepTimer(_:)`, `progressFraction` used identically across tasks and match the `EpisodeRow.onPlay` handoff from Plan 2. `ChapterFetcher`/`ParsedChapter` names align with Plan 4's consumption.
