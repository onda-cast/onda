# Onda Plan 7: Clips & Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clips — saved, annotated transcript-range excerpts of episodes, capturable from the transcript view or the lock screen, browsable/searchable in a Clips library, and playable as bounded segments.

**Architecture:** `Clip` is a SwiftData `@Model`. `ClipService` (`@MainActor @Observable`) creates clips (range → cue-text snapshot via pure `ClipTextSnapshot`), including lock-screen quick clips (trailing window snapped to cue boundaries). `PlaybackManager` gains bounded playback (`playClip`). `NowPlayingCenter` exposes `bookmarkCommand`. UI: selection mode in `TranscriptView`, a `ClipsView` reachable from Library.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, MediaPlayer (`MPRemoteCommandCenter.bookmarkCommand`), XCTest.

## Global Constraints

- Plan 1 Global Constraints apply verbatim (iOS 17, SwiftUI+SwiftData only, MV pattern, brutal style).
- Concurrency rules from memory/BUGS.md: explicit `@MainActor` services; **never** hand a MainActor-inherited closure to an ObjC callback API — bridge via `nonisolated` helpers with `@Sendable` completions; remote-command handlers hop via `Task { @MainActor }`.
- Feed-seconds canonical timeline. Clip text is a snapshot at creation; never rewritten.
- Quick-clip window: trailing **45 s** from current position, snapped outward to cue boundaries when a transcript exists (constant `quickClipWindow: TimeInterval = 45`).
- **Prerequisite check (Step 0 of Task 1):** if the parallel bug-#1 fix (nonisolated `requestSpeechAuthorization`) is not yet merged to `main`, apply it per docs/BUGS.md and re-enable the Transcribe button in `TranscriptView` (remove `.disabled(true)` + caption), verifying no crash.

**Depends on:** Plans 1–6 merged (v0.2.0+).

---

## File Structure

```
Onda/
  Models/
    Clip.swift               — @Model Clip
    ModelSchema.swift        — MODIFY: add Clip.self
  Clips/
    ClipTextSnapshot.swift   — pure: (cues, range) → snapped range + joined text
    ClipService.swift        — @Observable: makeClip / quickClip / delete / search
    ClipsView.swift          — clips library screen
    ClipRow.swift            — one clip row
    ClipEditSheet.swift      — note editing / review
  Playback/
    PlaybackManager.swift    — MODIFY: playClip(_:) bounded playback
    NowPlayingCenter.swift   — MODIFY: bookmarkCommand
  Player/
    TranscriptView.swift     — MODIFY: selection mode → create clip
  Shell/
    LibraryView.swift        — MODIFY: clips entry button
  OndaApp.swift              — MODIFY: inject ClipService, wire bookmark command
OndaTests/
  ClipTextSnapshotTests.swift
  ClipServiceTests.swift
  PlaybackManagerTests.swift — MODIFY: clip-bounded playback tests
```

---

### Task 1: Clip model + ClipTextSnapshot (pure)

**Files:**
- Create: `Onda/Models/Clip.swift`, `Onda/Clips/ClipTextSnapshot.swift`
- Modify: `Onda/Models/ModelSchema.swift`
- Test: `OndaTests/ClipTextSnapshotTests.swift`, `OndaTests/ModelTests.swift` (append)

**Interfaces:**
- Produces:
  - `@Model final class Clip { var startTime: TimeInterval; var endTime: TimeInterval; var text: String; var note: String?; var createdAt: Date; var needsReview: Bool; var episode: Episode? }` with `init(startTime:endTime:text:note:createdAt:needsReview:)`
  - `Episode` gains `@Relationship(deleteRule: .cascade, inverse: \Clip.episode) var clips: [Clip] = []`
  - `enum ClipTextSnapshot { static func snap(cues: [(start: TimeInterval, end: TimeInterval, text: String)], requestedStart: TimeInterval, requestedEnd: TimeInterval) -> (start: TimeInterval, end: TimeInterval, text: String) }` — expands the requested range outward to the boundaries of any overlapped cues and joins their text with spaces; with no overlapping cues returns the requested range and empty text.

- [ ] **Step 1: Write failing tests**

`OndaTests/ClipTextSnapshotTests.swift`:

```swift
//  ClipTextSnapshotTests.swift
import XCTest
@testable import Onda

@MainActor
final class ClipTextSnapshotTests: XCTestCase {
    private let cues: [(start: TimeInterval, end: TimeInterval, text: String)] = [
        (0, 10, "alpha"), (10, 20, "beta"), (20, 30, "gamma"), (30, 40, "delta"),
    ]

    func test_rangeSnapsOutwardToCueBoundaries() {
        let r = ClipTextSnapshot.snap(cues: cues, requestedStart: 12, requestedEnd: 24)
        XCTAssertEqual(r.start, 10); XCTAssertEqual(r.end, 30)
        XCTAssertEqual(r.text, "beta gamma")
    }

    func test_noOverlap_returnsRequestedRangeEmptyText() {
        let r = ClipTextSnapshot.snap(cues: [], requestedStart: 5, requestedEnd: 15)
        XCTAssertEqual(r.start, 5); XCTAssertEqual(r.end, 15)
        XCTAssertEqual(r.text, "")
    }

    func test_exactCueRange() {
        let r = ClipTextSnapshot.snap(cues: cues, requestedStart: 10, requestedEnd: 20)
        XCTAssertEqual(r.text, "beta")
    }
}
```

Append to `OndaTests/ModelTests.swift`:

```swift
    func test_clip_persistsLinkedToEpisode() throws {
        let ctx = try inMemoryContext()
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        let clip = Clip(startTime: 10, endTime: 30, text: "beta gamma", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip)
        ctx.insert(ep); ctx.insert(clip)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Clip>()).count, 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ClipTextSnapshotTests`
Expected: FAIL — `cannot find 'ClipTextSnapshot' in scope`.

- [ ] **Step 3: Implement**

`Onda/Models/Clip.swift`:

```swift
//  Clip.swift
import Foundation
import SwiftData

@Model
final class Clip {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String          // transcript snapshot at creation; may be empty
    var note: String?
    var createdAt: Date
    var needsReview: Bool     // true for lock-screen quick clips until edited
    var episode: Episode?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String,
         note: String?, createdAt: Date, needsReview: Bool) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.note = note
        self.createdAt = createdAt
        self.needsReview = needsReview
    }
}
```

Add to `Episode.swift`:
```swift
    @Relationship(deleteRule: .cascade, inverse: \Clip.episode)
    var clips: [Clip] = []
```
Append `Clip.self` to `ondaSchema`.

`Onda/Clips/ClipTextSnapshot.swift`:

```swift
//  ClipTextSnapshot.swift
import Foundation

enum ClipTextSnapshot {
    static func snap(cues: [(start: TimeInterval, end: TimeInterval, text: String)],
                     requestedStart: TimeInterval,
                     requestedEnd: TimeInterval) -> (start: TimeInterval, end: TimeInterval, text: String) {
        let overlapping = cues
            .filter { $0.end > requestedStart && $0.start < requestedEnd }
            .sorted { $0.start < $1.start }
        guard let first = overlapping.first, let last = overlapping.last else {
            return (requestedStart, requestedEnd, "")
        }
        return (min(first.start, requestedStart), max(last.end, requestedEnd),
                overlapping.map(\.text).joined(separator: " "))
    }
}
```

- [ ] **Step 4: Run to verify pass** (same command + ModelTests) — Expected: PASS.

- [ ] **Step 5: Commit** — `git add Onda/Models Onda/Clips OndaTests && git commit -m "feat: Clip model + ClipTextSnapshot range snapping"`

---

### Task 2: ClipService

**Files:**
- Create: `Onda/Clips/ClipService.swift`
- Test: `OndaTests/ClipServiceTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class ClipService`
  - `init(modelContext: ModelContext)`
  - `static let quickClipWindow: TimeInterval = 45`
  - `@discardableResult func makeClip(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval, note: String?, needsReview: Bool) -> Clip` — snaps via `ClipTextSnapshot` using the episode's transcript cues (empty cue list when none), inserts + saves.
  - `@discardableResult func quickClip(episode: Episode, at position: TimeInterval) -> Clip` — `makeClip(episode:requestedStart: max(0, position - quickClipWindow), requestedEnd: position, note: nil, needsReview: true)`
  - `func delete(_ clip: Clip)`
  - `func allClips() -> [Clip]` (newest first), `func search(_ query: String) -> [Clip]` (case-insensitive over `text` + `note`)

- [ ] **Step 1: Failing tests**

```swift
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

    func test_search_matchesTextAndNote() throws {
        let (ctx, ep) = try env()
        let svc = ClipService(modelContext: ctx)
        _ = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10, note: "remember this", needsReview: false)
        XCTAssertEqual(svc.search("alpha").count, 1)
        XCTAssertEqual(svc.search("remember").count, 1)
        XCTAssertEqual(svc.search("zzz").count, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure** — Expected: `cannot find 'ClipService'`.

- [ ] **Step 3: Implement**

```swift
//  ClipService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ClipService {
    static let quickClipWindow: TimeInterval = 45
    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    @discardableResult
    func makeClip(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval,
                  note: String?, needsReview: Bool) -> Clip {
        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { (start: $0.startTime, end: $0.endTime, text: $0.text) }
        let snapped = ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                            requestedEnd: requestedEnd)
        let clip = Clip(startTime: snapped.start, endTime: snapped.end, text: snapped.text,
                        note: note, createdAt: .now, needsReview: needsReview)
        clip.episode = episode
        episode.clips.append(clip)
        modelContext.insert(clip)
        try? modelContext.save()
        return clip
    }

    @discardableResult
    func quickClip(episode: Episode, at position: TimeInterval) -> Clip {
        makeClip(episode: episode, requestedStart: max(0, position - Self.quickClipWindow),
                 requestedEnd: position, note: nil, needsReview: true)
    }

    func delete(_ clip: Clip) {
        clip.episode?.clips.removeAll { $0 === clip }
        modelContext.delete(clip)
        try? modelContext.save()
    }

    func allClips() -> [Clip] {
        let d = FetchDescriptor<Clip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? modelContext.fetch(d)) ?? []
    }

    func search(_ query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return allClips() }
        return allClips().filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || ($0.note?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass.** — Expected: 3 tests PASS.
- [ ] **Step 5: Commit** — `"feat: ClipService (makeClip/quickClip/search/delete)"`

---

### Task 3: Clip-bounded playback

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`, `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Produces: `func playClip(_ clip: Clip)` — plays `clip.episode` from `clip.startTime`; when position reaches `clip.endTime`, pause (do NOT mark played / advance queue) and clear the bound. `private var clipEndBound: TimeInterval?` cleared on any manual `play/seek/skip`.

- [ ] **Step 1: Failing tests** (append to PlaybackManagerTests)

```swift
    func test_playClip_startsAtClipStart_andPausesAtClipEnd() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        let clip = Clip(startTime: 100, endTime: 160, text: "", note: nil,
                        createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip); ctx.insert(clip)
        pm.playClip(clip)
        XCTAssertEqual(engine.startAt, 100)
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
```

- [ ] **Step 2: Run to verify failure** — `no member 'playClip'`.

- [ ] **Step 3: Implement** — in `PlaybackManager`:

```swift
    private var clipEndBound: TimeInterval?

    func playClip(_ clip: Clip) {
        guard let ep = clip.episode else { return }
        play(ep)                                  // sets everything up (clears bound below)
        engine.seek(to: clip.startTime)
        positionSeconds = clip.startTime
        clipEndBound = clip.endTime
    }
```

In `play(_:)` add `clipEndBound = nil` at the top. In `skip(by:)` and `seek(toFraction:)` add `clipEndBound = nil` first. In `handleTimeUpdate(_:)`, before ad/outro logic:

```swift
        if let bound = clipEndBound, t >= bound {
            clipEndBound = nil
            engine.pause()
            isPlaying = false
            persistPosition()
            return
        }
```

Also load with correct start: replace `engine.load/seek` interplay — `play(ep)` loads at resume position, then we seek; acceptable (one extra seek). Ensure `play(_:)`'s `engine.load(url:startAt:)` uses `max(episode.playbackPosition, intro)` as today.

- [ ] **Step 4: Run to verify pass** (all PlaybackManagerTests). 
- [ ] **Step 5: Commit** — `"feat: clip-bounded playback in PlaybackManager"`

---

### Task 4: Lock-screen capture (bookmarkCommand)

**Files:**
- Modify: `Onda/Playback/NowPlayingCenter.swift`, `Onda/OndaApp.swift`, `Onda/Playback/PlaybackManager.swift`

**Interfaces:**
- `NowPlayingCenter.configureBookmarkCommand(_ handler: @escaping @MainActor () -> Void)` — enables `MPRemoteCommandCenter.shared().bookmarkCommand`, handler hops via `Task { @MainActor }` (never `assumeIsolated`).
- `PlaybackManager` gains `var onCaptureRequested: (() -> Void)?` invoked by the bookmark command; `OndaApp` wires it to `clips.quickClip(episode: playback.currentEpisode!, at: playback.positionSeconds)` (guarding nil) and shows a brief toast state on `PlaybackManager` (`var captureToast: String?` auto-cleared after 2 s) that `MiniPlayerView`/`NowPlayingView` overlay.

- [ ] **Step 1: Implement** (UI-adjacent glue; covered by ClipService tests + build):

`NowPlayingCenter`:
```swift
    func configureBookmarkCommand(_ handler: @escaping @MainActor () -> Void) {
        let cmd = MPRemoteCommandCenter.shared().bookmarkCommand
        cmd.isEnabled = true
        cmd.addTarget { _ in Task { @MainActor in handler() }; return .success }
    }
```

`PlaybackManager` additions:
```swift
    var onCaptureRequested: (() -> Void)?
    var captureToast: String?
    private var toastTask: Task<Void, Never>?

    func showCaptureToast(_ text: String) {
        captureToast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.captureToast = nil
        }
    }
```
and in `init`, after remote command config: `nowPlaying.configureBookmarkCommand { [weak self] in self?.onCaptureRequested?() }`.

`OndaApp.init` (after building `pm` and `ClipService`):
```swift
            let cs = ClipService(modelContext: c.mainContext)
            _clips = State(initialValue: cs)
            pm.onCaptureRequested = { [weak pm] in
                guard let pm, let ep = pm.currentEpisode else { return }
                cs.quickClip(episode: ep, at: pm.positionSeconds)
                pm.showCaptureToast("Clipped last \(Int(ClipService.quickClipWindow))s")
            }
```
Inject `.environment(clips)`. Overlay in `NowPlayingView` (and mini-player) rendering `playback.captureToast` in the prototype's toast style (bottom pill, `toastIn`-like appearance).

- [ ] **Step 2: Build + full test run** — Expected: BUILD SUCCEEDED, all tests pass.
- [ ] **Step 3: Commit** — `"feat: lock-screen quick-clip via bookmarkCommand + capture toast"`

---

### Task 5: Transcript selection → clip sheet

**Files:**
- Modify: `Onda/Player/TranscriptView.swift`
- Create: `Onda/Clips/ClipEditSheet.swift`

**Interfaces:**
- `TranscriptView` gains a "Select" toolbar toggle. In selection mode, cue taps set/extend a range (first tap = anchor, second tap = extend; tapping inside clears to new anchor); selected cues get accent-wash background; a bottom bar shows "Clip N cues" → presents `ClipEditSheet`.
- `ClipEditSheet(episode:requestedStart:requestedEnd:)` — shows the snapped text preview (via `ClipTextSnapshot` on the episode's cues), a note `TextField`, Save → `clips.makeClip(...)`, Cancel. Also `ClipEditSheet(clip:)` variant for editing an existing clip's note (sets `needsReview = false` on save).

- [ ] **Step 1: Implement** `ClipEditSheet`:

```swift
//  ClipEditSheet.swift
import SwiftUI

struct ClipEditSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(\.dismiss) private var dismiss

    let episode: Episode?
    let requestedStart: TimeInterval
    let requestedEnd: TimeInterval
    let existing: Clip?
    @State private var note: String

    init(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval) {
        self.episode = episode; self.requestedStart = requestedStart
        self.requestedEnd = requestedEnd; self.existing = nil
        _note = State(initialValue: "")
    }
    init(clip: Clip) {
        self.episode = clip.episode; self.requestedStart = clip.startTime
        self.requestedEnd = clip.endTime; self.existing = clip
        _note = State(initialValue: clip.note ?? "")
    }

    private var previewText: String {
        if let existing { return existing.text }
        guard let episode else { return "" }
        let cues = (episode.transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
            .map { (start: $0.startTime, end: $0.endTime, text: $0.text) }
        return ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                     requestedEnd: requestedEnd).text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Excerpt").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    Text(previewText.isEmpty ? "(no transcript for this range)" : previewText)
                        .font(.system(size: 14.5)).foregroundStyle(theme.color(.textSecondary))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    Text("Note").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    TextField("Why does this matter?", text: $note, axis: .vertical)
                        .lineLimit(3...6).padding(12)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }.padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle(existing == nil ? "New Clip" : "Edit Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        if let existing {
            existing.note = note.isEmpty ? nil : note
            existing.needsReview = false
        } else if let episode {
            clips.makeClip(episode: episode, requestedStart: requestedStart,
                           requestedEnd: requestedEnd,
                           note: note.isEmpty ? nil : note, needsReview: false)
        }
        dismiss()
    }
}
```

- [ ] **Step 2: Add selection mode to TranscriptView** — `@State private var selecting = false`, `@State private var selStart: Int?`, `@State private var selEnd: Int?`, `@State private var showClipSheet = false`. Toolbar: `Button(selecting ? "Done" : "Select") { selecting.toggle(); selStart = nil; selEnd = nil }`. In `transcriptList` cue button action: when `selecting`, set anchor/extend indices instead of seeking; background highlights indices in `selStart...selEnd`. Bottom bar (only when a range exists): "Clip selection" button → `showClipSheet = true`; sheet presents `ClipEditSheet(episode: episode, requestedStart: cues[lo].startTime, requestedEnd: cues[hi].endTime)`.

- [ ] **Step 3: Build + run; commit** — `"feat: transcript selection mode + ClipEditSheet"`

---

### Task 6: Clips library screen

**Files:**
- Create: `Onda/Clips/ClipsView.swift`, `Onda/Clips/ClipRow.swift`
- Modify: `Onda/Shell/LibraryView.swift`

**Interfaces:**
- `ClipRow(clip:onPlay:)` — show title, timestamp range, excerpt (3 lines), note (accent), `needsReview` badge ("NEW"), play button.
- `ClipsView` — search field (ClipService.search), list newest-first, tap row → `ClipEditSheet(clip:)`, play button → `playback.playClip(clip)`, swipe-to-delete → `clips.delete`.
- `LibraryView` header gains a bookmark icon button (beside search) presenting `ClipsView` as a sheet.

- [ ] **Step 1: Implement both views** (brutal style: cards with `brutalBorder` + `hardShadow`; row shows `clip.episode?.podcast?.title` uppercase header, `timeStr(start)–timeStr(end)`).
- [ ] **Step 2: Wire Library entry**: `Image(systemName: "bookmark")` button + `.sheet`.
- [ ] **Step 3: Build, full test run, install to simulator, verify manually: select cues → clip → appears in Clips; lock-screen bookmark → quick clip with NEW badge; play button plays just the range; search filters.**
- [ ] **Step 4: Commit** — `"feat: Clips library (search, edit, bounded replay, delete)"`

---

### Task 7: Regression + smoke + tag

- [ ] **Step 1:** Full suite: expect all prior tests + new Clip suites green.
- [ ] **Step 2:** Manual smoke (user): transcript selection clip; lock-screen capture while playing (Simulator: Now Playing widget bookmark button); clips library flows; regression on playback/downloads.
- [ ] **Step 3:** Merge per finishing-a-development-branch; tag `v0.3.0`.

---

## Self-Review

- **Spec coverage (v0.3 addendum):** Clip model w/ snapshot semantics ✓; transcript-selection creation ✓; lock-screen quick clip (45 s, cue-snapped, needsReview) ✓; clips library w/ search/edit/delete ✓; bounded replay that neither marks played nor advances queue ✓; bug-#1 fix precondition ✓; deferred items untouched ✓.
- **Placeholder scan:** Tasks 5/6 steps 1–2 describe UI wiring with full code for the nontrivial sheet and exact state/behavior for the rest — consistent with how Plans 3/5 handled view glue. No TBDs.
- **Type consistency:** `ClipService.makeClip/quickClip/search/delete/allClips`, `ClipTextSnapshot.snap`, `PlaybackManager.playClip/onCaptureRequested/captureToast`, `NowPlayingCenter.configureBookmarkCommand` used identically across tasks; `Clip` init matches all call sites; concurrency rules follow the project memory (no `assumeIsolated`, `@MainActor` service, hop in remote handler).
