# Onda Plan 8: Smart Queues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small fixed set of computed smart queues — Unplayed, Downloaded, Recently Added, Shortest First — surfaced in Library. Tapping one materializes it into the existing manual `QueueItem` list and starts playback, so it inherits all existing queue behavior (reorder, play-through, resume) with no new playback logic.

**Architecture:** `SmartQueue` is a pure enum (no persisted rule model — predefined filters only, per the v0.6 spec decision against a custom rule builder). `PlaybackManager` gains `startSmartQueue(_:)`, which replaces the current `QueueItem` rows with a snapshot of the filtered/ordered episode list and plays the first entry. UI: a row of four chips above the Library show grid.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest.

## Global Constraints

- Plan 1 Global Constraints apply verbatim (iOS 17, SwiftUI+SwiftData only, MV pattern, brutal style).
- No new persisted model — smart queues are computed, not user-authored (v0.6 spec: "Predefined filters" over a custom rule builder).
- Materializing a smart queue fully replaces the current manual queue (not appended) — starting a smart queue is a deliberate "listen through this" action, not a merge.

**Depends on:** Plans 1–7 merged (v0.3.0+).

---

## File Structure

```
Onda/
  Library/
    SmartQueue.swift        — pure enum: cases + apply(to:now:)
    LibraryView.swift        — MODIFY: smart-queue chip row above show grid
  Playback/
    PlaybackManager.swift    — MODIFY: startSmartQueue(_:), clearQueue()
OndaTests/
  SmartQueueTests.swift
  PlaybackManagerTests.swift — MODIFY: smart-queue materialization tests
```

---

### Task 1: `SmartQueue` enum (pure)

**Files:**
- Create: `Onda/Library/SmartQueue.swift`
- Test: `OndaTests/SmartQueueTests.swift`

**Interfaces:**
- Produces: `enum SmartQueue: String, CaseIterable, Sendable { case unplayed, downloaded, recentlyAdded, shortestFirst }` with `var label: String` and `@MainActor func apply(to episodes: [Episode], now: Date = .now) -> [Episode]`.
  - `.unplayed` — unplayed episodes, newest publish date first.
  - `.downloaded` — downloaded AND unplayed episodes, newest publish date first.
  - `.recentlyAdded` — episodes published within the last 7 days (`now.addingTimeInterval(-7*24*3600)...now`), newest first.
  - `.shortestFirst` — unplayed episodes, shortest duration first.

- [ ] **Step 1: Write failing tests**

`OndaTests/SmartQueueTests.swift`:

```swift
//  SmartQueueTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class SmartQueueTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func episode(in ctx: ModelContext, guid: String, daysAgo: Double, duration: TimeInterval,
                         played: Bool = false, downloaded: Bool = false) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid).xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: guid, title: guid, publishDate: Date.now.addingTimeInterval(-daysAgo * 86400),
                         duration: duration, audioURL: URL(string: "https://ex.com/\(guid).mp3")!,
                         notes: "", played: played)
        ep.podcast = pod; pod.episodes.append(ep)
        if downloaded {
            let df = DownloadedFile(localFileName: "\(guid).mp3", fileSizeBytes: 100, downloadedAt: .now)
            df.episode = ep; ep.downloadedFile = df; ctx.insert(df)
        }
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_unplayed_excludesPlayed_newestFirst() throws {
        let c = try ctx()
        let old = episode(in: c, guid: "old", daysAgo: 10, duration: 100)
        let new = episode(in: c, guid: "new", daysAgo: 1, duration: 100)
        let done = episode(in: c, guid: "done", daysAgo: 0.5, duration: 100, played: true)
        let result = SmartQueue.unplayed.apply(to: [old, new, done])
        XCTAssertEqual(result.map(\.guid), ["new", "old"])
    }

    func test_downloaded_onlyDownloadedAndUnplayed() throws {
        let c = try ctx()
        let a = episode(in: c, guid: "a", daysAgo: 1, duration: 100, downloaded: true)
        let b = episode(in: c, guid: "b", daysAgo: 2, duration: 100, downloaded: false)
        let playedDownloaded = episode(in: c, guid: "pd", daysAgo: 0, duration: 100, played: true, downloaded: true)
        let result = SmartQueue.downloaded.apply(to: [a, b, playedDownloaded])
        XCTAssertEqual(result.map(\.guid), ["a"])
    }

    func test_recentlyAdded_last7Days() throws {
        let c = try ctx()
        let recent = episode(in: c, guid: "recent", daysAgo: 3, duration: 100)
        let old = episode(in: c, guid: "old", daysAgo: 30, duration: 100)
        let result = SmartQueue.recentlyAdded.apply(to: [recent, old])
        XCTAssertEqual(result.map(\.guid), ["recent"])
    }

    func test_shortestFirst_sortsByDuration_excludesPlayed() throws {
        let c = try ctx()
        let long = episode(in: c, guid: "long", daysAgo: 1, duration: 3600)
        let short = episode(in: c, guid: "short", daysAgo: 1, duration: 600)
        let playedShort = episode(in: c, guid: "ps", daysAgo: 1, duration: 100, played: true)
        let result = SmartQueue.shortestFirst.apply(to: [long, short, playedShort])
        XCTAssertEqual(result.map(\.guid), ["short", "long"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SmartQueueTests`
Expected: FAIL — `cannot find 'SmartQueue' in scope`.

- [ ] **Step 3: Implement**

`Onda/Library/SmartQueue.swift`:

```swift
//  SmartQueue.swift
import Foundation

enum SmartQueue: String, CaseIterable, Sendable {
    case unplayed, downloaded, recentlyAdded, shortestFirst

    var label: String {
        switch self {
        case .unplayed: return "Unplayed"
        case .downloaded: return "Downloaded"
        case .recentlyAdded: return "Recently Added"
        case .shortestFirst: return "Shortest First"
        }
    }

    @MainActor
    func apply(to episodes: [Episode], now: Date = .now) -> [Episode] {
        switch self {
        case .unplayed:
            return episodes.filter { !$0.played }
                .sorted { $0.publishDate > $1.publishDate }
        case .downloaded:
            return episodes.filter { !$0.played && $0.downloadedFile != nil }
                .sorted { $0.publishDate > $1.publishDate }
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            return episodes.filter { $0.publishDate >= cutoff && $0.publishDate <= now }
                .sorted { $0.publishDate > $1.publishDate }
        case .shortestFirst:
            return episodes.filter { !$0.played }
                .sorted { $0.duration < $1.duration }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — Expected: 4 tests PASS.
- [ ] **Step 5: Commit** — `git add Onda/Library/SmartQueue.swift OndaTests/SmartQueueTests.swift && git commit -m "feat: SmartQueue predefined filters (unplayed/downloaded/recent/shortest)"`

---

### Task 2: `PlaybackManager.startSmartQueue(_:)`

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`, `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Produces: `func startSmartQueue(_ episodes: [Episode])` — clears all existing `QueueItem` rows and the in-memory `queue`, inserts new `QueueItem` rows for `episodes.dropFirst()` at positions `0..<`, appends them to `queue`, then calls `play(episodes[0])`. No-op if `episodes` is empty.
- Consumes: existing `QueueItem` model (`Models/QueueItem.swift`), existing `play(_:)`/`queue`/`modelContext`.

- [ ] **Step 1: Write failing tests** (append to `PlaybackManagerTests.swift`)

```swift
    func test_startSmartQueue_playsFirst_queuesRest_replacesExistingQueue() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
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
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        pm.startSmartQueue([])
        XCTAssertNil(engine.loadedURL)
        XCTAssertFalse(pm.isPlaying)
    }
```

- [ ] **Step 2: Run to verify failure** — Expected: `value of type 'PlaybackManager' has no member 'startSmartQueue'`.

- [ ] **Step 3: Implement** — add to the `// MARK: Queue` section of `PlaybackManager`:

```swift
    func startSmartQueue(_ episodes: [Episode]) {
        guard let first = episodes.first else { return }
        clearQueue()
        for ep in episodes.dropFirst() {
            let item = QueueItem(episode: ep, position: queue.count)
            modelContext.insert(item)
            queue.append(ep)
        }
        try? modelContext.save()
        play(first)
    }

    private func clearQueue() {
        let items = (try? modelContext.fetch(FetchDescriptor<QueueItem>())) ?? []
        for it in items { modelContext.delete(it) }
        queue.removeAll()
    }
```

- [ ] **Step 4: Run to verify pass** — Expected: all `PlaybackManagerTests` PASS.
- [ ] **Step 5: Commit** — `"feat: PlaybackManager.startSmartQueue materializes a smart queue and replaces the manual queue"`

---

### Task 3: Library UI — smart-queue chip row

**Files:**
- Modify: `Onda/Shell/LibraryView.swift`

**Interfaces:**
- Consumes: `SmartQueue.allCases`, `SmartQueue.apply(to:)`, `PlaybackManager.startSmartQueue(_:)`.
- A horizontal row of 4 chips (`SmartQueue.allCases`, in enum declaration order) between the Library header and the show grid, hidden when `shows.isEmpty`. Tapping a chip computes `chip.apply(to: shows.flatMap(\.episodes))` and calls `playback.startSmartQueue(result)`; a chip whose filtered result is empty is disabled (`.opacity(0.4)`, non-tappable) rather than hidden, so the set of options stays visually stable.

- [ ] **Step 1: Implement** — in `LibraryView`, add `@Environment(PlaybackManager.self) private var playback` and, inside the `VStack` right after the header `HStack` (before the `if shows.isEmpty` branch), insert:

```swift
                    if !shows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(SmartQueue.allCases, id: \.self) { sq in
                                    let episodes = sq.apply(to: shows.flatMap(\.episodes))
                                    Button {
                                        playback.startSmartQueue(episodes)
                                    } label: {
                                        Text(sq.label.uppercased())
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.color(.textSecondary))
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(episodes.isEmpty)
                                    .opacity(episodes.isEmpty ? 0.4 : 1)
                                }
                            }.padding(.horizontal, 20)
                        }
                        .padding(.top, 16)
                    }
```

- [ ] **Step 2: Build + full test run**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, all tests PASS (prior suites + `SmartQueueTests` + new `PlaybackManagerTests`).

- [ ] **Step 3: Manual smoke (user)** — install to simulator: subscribe to a show with a few unplayed episodes, tap "Unplayed" in Library, confirm playback starts on the newest unplayed episode and the rest appear in the Up Next queue in order; confirm a chip with no matches (e.g. "Downloaded" with nothing downloaded) renders disabled/dimmed rather than doing nothing silently.

- [ ] **Step 4: Commit** — `"feat: Smart Queue chip row in Library"`

---

## Self-Review

- **Spec coverage:** predefined filters only (no rule builder) ✓; materializes into existing `QueueItem` list ✓; surfaced above the show grid ✓.
- **Placeholder scan:** none — full code in every step.
- **Type consistency:** `SmartQueue.apply(to:now:)`, `PlaybackManager.startSmartQueue(_:)`/`clearQueue()` used identically across tasks; `SmartQueue.allCases` ordering matches the chip row's expected left-to-right presentation.
