# Fullscreen-Player Clips Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start/end clip capture from the fullscreen player (`NowPlayingView`), opening a new `ClipReviewSheet` where the user can listen to the clip on a loop and adjust its start/end times before saving.

**Architecture:** Look-back capture (start = position − 5s) held as view state in `NowPlayingView`; a new episode-aware looping preview mode in `PlaybackManager` (snapshot listener's spot on sheet open, restore on close); a new `ClipReviewSheet` that replaces the note-only `ClipEditSheet` at every call site and saves **exact** user times via new `ClipService.makeClipExact`/`updateClip` and a non-expanding `ClipTextSnapshot.text` helper.

**Tech Stack:** SwiftUI, SwiftData, XCTest. Project regenerated with XcodeGen after file add/delete.

**Spec:** `docs/superpowers/specs/2026-07-18-fullscreen-player-clips-design.md`

## Global Constraints

- All times are **original feed seconds** (canonical timeline). Never store wall-clock-adjusted times.
- Look-back cushion: **5 s**. Minimum clip length: **1 s** (`end ≥ start + 1`).
- The interactive editor stores the user's **exact** times — no outward cue snapping. `quickClip` (lock screen) keeps its existing snapping behavior.
- Use `.scaledFont(size, weight:)`, `brutalHeader`, `brutalBorder`, `hardShadow`, `theme.color(_:)` (Theme conventions). Small white text on an accent fill uses `.accentStrong`.
- **Simulator discipline (this Mac runs concurrent sessions):** never test on a shared/booted device. Create a dedicated sim and isolated DerivedData once, reuse for every test step:

  ```sh
  xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
  UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
  DD=.dd-clips   # repo-local DerivedData; do NOT git add it
  ```

  Every `xcodebuild` command below assumes `UDID` and `DD` are set in that shell invocation (shell state does not persist between tool calls — re-run the two lines above in each call). Only unit tests (`OndaTests`) are needed; never run the full scheme test action (UI tests + speech tests are slow and need TCC seeding).

- Test command template (fill in `-only-testing`):

  ```sh
  xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
    -derivedDataPath "$DD" -only-testing:OndaTests/<ClassName> 2>&1 | tail -20
  ```

---

### Task 1: `ClipTextSnapshot.text` — non-expanding excerpt derivation

**Files:**
- Modify: `Onda/Clips/ClipTextSnapshot.swift`
- Test: `OndaTests/ClipTextSnapshotTests.swift`

**Interfaces:**
- Consumes: existing `CueSpan` struct (`start`, `end`, `text`).
- Produces: `static func text(cues: [CueSpan], start: TimeInterval, end: TimeInterval) -> String` on `ClipTextSnapshot` — joins the text of cues overlapping `[start, end)` **without** moving the boundaries; `""` when nothing overlaps. Task 2 and Task 4 call this.

- [ ] **Step 1: Write the failing tests**

Append inside `final class ClipTextSnapshotTests` in `OndaTests/ClipTextSnapshotTests.swift` (the `cues` fixture — alpha 0–10, beta 10–20, gamma 20–30, delta 30–40 — already exists at the top of the class):

```swift
    // MARK: - text(cues:start:end:) — exact-times variant (no boundary expansion)

    func test_text_joinsOverlappingCues() {
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 12, end: 24), "beta gamma")
    }

    func test_text_noOverlap_returnsEmpty() {
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 45, end: 50), "")
        XCTAssertEqual(ClipTextSnapshot.text(cues: [], start: 5, end: 15), "")
    }

    func test_text_edgeTouchingCuesExcluded() {
        // alpha ends exactly at start (10) and delta starts exactly at end (30):
        // half-open [start, end) excludes both.
        XCTAssertEqual(ClipTextSnapshot.text(cues: cues, start: 10, end: 30), "beta gamma")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/ClipTextSnapshotTests 2>&1 | tail -20
```

Expected: **build failure** — `type 'ClipTextSnapshot' has no member 'text'`.

- [ ] **Step 3: Write the implementation**

Append inside `enum ClipTextSnapshot` in `Onda/Clips/ClipTextSnapshot.swift`:

```swift
    /// Joins the text of cues overlapping [start, end) WITHOUT moving the boundaries —
    /// the interactive editor's excerpt, which must track the user's exact times.
    static func text(cues: [CueSpan], start: TimeInterval, end: TimeInterval) -> String {
        cues.filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
            .map(\.text).joined(separator: " ")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'ClipTextSnapshotTests' passed` (6 tests).

- [ ] **Step 5: Commit**

```sh
git add Onda/Clips/ClipTextSnapshot.swift OndaTests/ClipTextSnapshotTests.swift
git commit -m "feat: non-expanding ClipTextSnapshot.text for exact-times clip excerpts"
```

---

### Task 2: `ClipService` exact-times create + update

**Files:**
- Modify: `Onda/Clips/ClipService.swift`
- Test: `OndaTests/ClipServiceTests.swift`

**Interfaces:**
- Consumes: existing `Clip` model, `SearchIndex.upsert/delete` (index docs are keyed by `(kind, episodeGuid, startTime)`), private `reindex(_:)`.
- Produces (Task 4 calls both):
  - `@discardableResult func makeClipExact(episode: Episode, start: TimeInterval, end: TimeInterval, text: String, note: String?, needsReview: Bool) -> Clip`
  - `func updateClip(_ clip: Clip, start: TimeInterval, end: TimeInterval, text: String, note: String?)` — sets `needsReview = false`, deletes the stale index doc (old `startTime` key) before re-timing, then re-indexes.

- [ ] **Step 1: Write the failing tests**

Append inside `final class ClipServiceTests` in `OndaTests/ClipServiceTests.swift` (the `env()` helper builds an episode with cues alpha 0–10 … delta 30–40):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/ClipServiceTests 2>&1 | tail -20
```

Expected: **build failure** — no members `makeClipExact` / `updateClip`.

- [ ] **Step 3: Write the implementation**

Add to `ClipService` (`Onda/Clips/ClipService.swift`), after `makeClip`:

```swift
    /// Creates a clip at the user's exact times (no cue snapping) — the Clip Review sheet's
    /// save path. `text` is the caller-derived excerpt (see `ClipTextSnapshot.text`).
    @discardableResult
    func makeClipExact(episode: Episode, start: TimeInterval, end: TimeInterval,
                       text: String, note: String?, needsReview: Bool) -> Clip {
        let clip = Clip(startTime: start, endTime: end, text: text,
                        note: note, createdAt: .now, needsReview: needsReview)
        clip.episode = episode
        episode.clips.append(clip)
        modelContext.insert(clip)
        try? modelContext.save()
        reindex(clip)
        return clip
    }

    /// Applies edited times/text/note from the Clip Review sheet. Index docs are keyed by
    /// startTime, so the stale doc is deleted before the time changes.
    func updateClip(_ clip: Clip, start: TimeInterval, end: TimeInterval,
                    text: String, note: String?) {
        if let guid = clip.episode?.guid {
            try? index?.delete(kind: "clip", episodeGuid: guid, startTime: clip.startTime)
        }
        clip.startTime = start
        clip.endTime = end
        clip.text = text
        clip.note = note
        clip.needsReview = false
        try? modelContext.save()
        reindex(clip)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'ClipServiceTests' passed` (9 tests).

- [ ] **Step 5: Commit**

```sh
git add Onda/Clips/ClipService.swift OndaTests/ClipServiceTests.swift
git commit -m "feat: ClipService.makeClipExact + updateClip for exact-times clip editing"
```

---

### Task 3: `PlaybackManager` — episode-aware looping clip preview

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`
- Test: `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Consumes: existing `engine` (`PlayerEngine`), `play(_:autoDownload:)`, `persistPosition()`, `handleTimeUpdate(_:)`, `skip(by:)`, `seek(toFraction:)`, `clipEndBound`.
- Produces (Task 4's sheet calls all four):
  - `func beginClipPreview()` — snapshot `(currentEpisode, positionSeconds, isPlaying)`, pause, persist.
  - `func previewRange(episode: Episode, start: TimeInterval, end: TimeInterval)` — load `episode` if not current (no auto-download), seek to `start`, loop-play `[start, end)`.
  - `func stopPreviewPlayback()` — stop looping, pause, leave the playhead in place.
  - `func endClipPreview()` — restore snapshotted episode + position; resume iff the listener was playing.

Behavior contract: while previewing, time ticks **never** persist position, mark played, run ad logic, or trim outro — the tick loops back to `start` when `t ≥ end` and otherwise does nothing. A manual `skip`/`seek` cancels the preview loop (same as `clipEndBound`).

- [ ] **Step 1: Write the failing tests**

Append a new extension at the bottom of `OndaTests/PlaybackManagerTests.swift` (uses the file's existing `FakeEngine`, `makeContext()`, `makeAppSettings()`, `makeEpisode(...)` helpers):

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/PlaybackManagerTests 2>&1 | tail -20
```

Expected: **build failure** — no members `beginClipPreview` / `previewRange` / `endClipPreview`.

- [ ] **Step 3: Write the implementation**

In `Onda/Playback/PlaybackManager.swift`:

**(a)** Below `private var clipEndBound: TimeInterval?` (near line 150), add:

```swift
    // MARK: Clip preview (Clip Review sheet)
    // Scoped, looping playback of a candidate clip range. Opening the sheet snapshots the
    // listener's spot (episode/position/play-state); closing restores it, so previewing can
    // never lose their place. While a preview is active, ticks do nothing but loop.
    private var clipPreviewRange: (start: TimeInterval, end: TimeInterval)?
    private var preClipPreview: (episode: Episode?, position: TimeInterval, wasPlaying: Bool)?

    /// Called when the Clip Review sheet appears: pause and remember where the listener was.
    /// Balanced by ``endClipPreview()`` on dismiss.
    func beginClipPreview() {
        preClipPreview = (currentEpisode, positionSeconds, isPlaying)
        engine.pause()
        isPlaying = false
        persistPosition()
    }

    /// Plays just `[start, end)` of `episode`, looping back to `start` at the end bound.
    /// Loads the episode (without auto-download) when it isn't the current one.
    func previewRange(episode: Episode, start: TimeInterval, end: TimeInterval) {
        if currentEpisode?.guid != episode.guid { play(episode, autoDownload: false) }
        engine.seek(to: start)
        positionSeconds = start
        clipPreviewRange = (start, end)
        engine.play()
        isPlaying = true
    }

    /// Stops preview playback, leaving the playhead where it is (used by the sheet's stop
    /// button, and by "Set to playhead" which reads ``positionSeconds`` afterwards).
    func stopPreviewPlayback() {
        clipPreviewRange = nil
        engine.pause()
        isPlaying = false
    }

    /// Called when the Clip Review sheet dismisses: restore the pre-preview episode and
    /// position, resuming only if the listener was playing.
    func endClipPreview() {
        clipPreviewRange = nil
        guard let snapshot = preClipPreview else { return }
        preClipPreview = nil
        guard let ep = snapshot.episode else {
            // Nothing was loaded before the sheet (e.g. editing from the Clips list on a
            // fresh launch): just stop; the clip's episode stays loaded, paused.
            engine.pause()
            isPlaying = false
            return
        }
        if currentEpisode?.guid != ep.guid { play(ep, autoDownload: false) }
        engine.seek(to: snapshot.position)
        positionSeconds = snapshot.position
        if snapshot.wasPlaying {
            engine.play()
            isPlaying = true
        } else {
            engine.pause()
            isPlaying = false
        }
        persistPosition()
    }
```

**(b)** At the top of `handleTimeUpdate(_:)`, insert the preview branch between `positionSeconds = t` and `guard let ep = currentEpisode`:

```swift
    private func handleTimeUpdate(_ t: TimeInterval) {
        positionSeconds = t

        // Clip preview: bounce back to the range start at the end bound; skip everything
        // else (persist, played-marking, ads, outro) — preview must not touch stored state.
        if let range = clipPreviewRange {
            if t >= range.end {
                engine.seek(to: range.start)
                positionSeconds = range.start
            }
            return
        }

        guard let ep = currentEpisode else { return }
```

**(c)** Clear the preview on manual seeks, next to the existing `clipEndBound = nil` lines in `skip(by:)` and `seek(toFraction:)`:

```swift
    func skip(by seconds: TimeInterval) {
        clipEndBound = nil
        clipPreviewRange = nil
        let target = max(0, min(durationSeconds, positionSeconds + seconds))
        engine.seek(to: target); positionSeconds = target
    }

    /// Seeks to a fraction `0...1` of the episode duration (the scrubber's seek path).
    func seek(toFraction f: Double) {
        clipEndBound = nil
        clipPreviewRange = nil
        let target = max(0, min(durationSeconds, durationSeconds * f))
        engine.seek(to: target); positionSeconds = target
    }
```

**(d)** `play(_:autoDownload:)` starts a fresh episode, so a stale preview loop must not survive it. Add `clipPreviewRange = nil` next to the existing `clipEndBound = nil` first line of `play`:

```swift
    func play(_ episode: Episode, autoDownload: Bool = true) {
        clipEndBound = nil
        clipPreviewRange = nil
```

(Note: `previewRange`/`endClipPreview` call `play` *before* setting `clipPreviewRange`, so this ordering is safe.)

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'PlaybackManagerTests' passed` (all existing tests + 6 new).

- [ ] **Step 5: Commit**

```sh
git add Onda/Playback/PlaybackManager.swift OndaTests/PlaybackManagerTests.swift
git commit -m "feat: episode-aware looping clip preview in PlaybackManager"
```

---

### Task 4: `ClipReviewSheet` — replaces `ClipEditSheet` everywhere

**Files:**
- Create: `Onda/Clips/ClipReviewSheet.swift`
- Delete: `Onda/Clips/ClipEditSheet.swift`
- Modify: `Onda/Clips/ClipsView.swift:84` (sheet presentation), `Onda/Player/TranscriptView.swift:132-138` (sheet presentation)
- Test: build + existing suites (view file; logic lives in Tasks 1–3's tested units)

**Interfaces:**
- Consumes: `ClipTextSnapshot.text(cues:start:end:)` (Task 1); `ClipService.makeClipExact(...)`/`updateClip(...)` (Task 2); `PlaybackManager.beginClipPreview()`/`previewRange(episode:start:end:)`/`stopPreviewPlayback()`/`endClipPreview()` (Task 3); `NowPlayingView.parseTimecode(_:)` (existing, tested).
- Produces: `struct ClipReviewSheet: View` with `init(episode: Episode, start: TimeInterval, end: TimeInterval)` (pending new clip) and `init(clip: Clip)` (edit existing), plus `static let minLength: TimeInterval = 1`. Task 5 presents the first init; `ClipsView`/`TranscriptView` use them here.

- [ ] **Step 1: Create `Onda/Clips/ClipReviewSheet.swift`**

```swift
//  ClipReviewSheet.swift
//  The single clip editor: loop-listen to the range, adjust start/end (nudge buttons,
//  type-a-timecode, set-to-playhead), and annotate. Replaces the old note-only ClipEditSheet.
//  Opening pauses the listener's episode and snapshots their spot; closing restores it
//  (PlaybackManager.beginClipPreview/endClipPreview).
import SwiftUI

struct ClipReviewSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ClipService.self) private var clips
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss

    /// A clip can never be shorter than this; every edit clamps against it.
    static let minLength: TimeInterval = 1

    let episode: Episode?
    let existing: Clip?
    @State private var start: TimeInterval
    @State private var end: TimeInterval
    @State private var note: String
    @State private var previewing = false
    @State private var editingField: TimeField?
    @State private var typedTime = ""

    enum TimeField { case start, end }

    init(episode: Episode, start: TimeInterval, end: TimeInterval) {
        self.episode = episode; self.existing = nil
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _note = State(initialValue: "")
    }

    init(clip: Clip) {
        self.episode = clip.episode; self.existing = clip
        _start = State(initialValue: clip.startTime)
        _end = State(initialValue: clip.endTime)
        _note = State(initialValue: clip.note ?? "")
    }

    // End-of-capture clamps can push `end` past a mis-reported feed duration; never clamp below it.
    private var duration: TimeInterval { max(episode?.duration ?? 0, end) }

    private var excerpt: String {
        guard let episode else { return "" }
        let cues = (episode.transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
            .map { CueSpan(start: $0.startTime, end: $0.endTime, text: $0.text) }
        return ClipTextSnapshot.text(cues: cues, start: start, end: end)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewButton
                    timeRow(label: "Start", field: .start)
                    timeRow(label: "End", field: .end)
                    Text("Excerpt").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    Text(excerpt.isEmpty ? "(no transcript for this range)" : excerpt)
                        .scaledFont(14.5).foregroundStyle(theme.color(.textSecondary))
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
            .alert("Set \(editingField == .end ? "End" : "Start") Time",
                   isPresented: Binding(get: { editingField != nil },
                                        set: { if !$0 { editingField = nil } })) {
                TextField("1:23:45", text: $typedTime)
                    .keyboardType(.numbersAndPunctuation)
                Button("Set") {
                    if let field = editingField, let t = NowPlayingView.parseTimecode(typedTime) {
                        setTime(field, to: t)
                    }
                    editingField = nil
                }
                Button("Cancel", role: .cancel) { editingField = nil }
            } message: {
                Text("Enter a time like 12:34, 1:02:30, or seconds.")
            }
        }
        .onAppear { playback.beginClipPreview() }
        .onDisappear { playback.endClipPreview() }
    }

    private var previewButton: some View {
        Button {
            if previewing {
                playback.stopPreviewPlayback()
            } else if let episode {
                playback.previewRange(episode: episode, start: start, end: end)
            }
            previewing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: previewing ? "stop.fill" : "play.fill")
                    .scaledFont(15, weight: .bold)
                Text(previewing ? "Stop" : "Preview Clip (\(Int(end - start))s)")
                    .scaledFont(15, weight: .bold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(theme.color(.accentStrong)).brutalBorder(width: 2)
        }
        .buttonStyle(.plain)
        .disabled(episode == nil)
        .accessibilityIdentifier("clip-preview-button")
    }

    private func timeRow(label: String, field: TimeField) -> some View {
        let value = field == .start ? start : end
        return HStack(spacing: 8) {
            Text(label).brutalHeader(size: 13)
                .foregroundStyle(theme.color(.textTertiary))
                .frame(width: 44, alignment: .leading)
            // Tappable timecode → type an exact time (same parser as the scrubber's jump alert).
            Button { typedTime = ""; editingField = field } label: {
                Text(timecode(value))
                    .scaledFont(15, weight: .bold).monospacedDigit()
                    .foregroundStyle(theme.color(.text))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) time \(timecode(value)), tap to type a time")
            Spacer(minLength: 0)
            nudgeButton("minus", field: field, tap: -1, longPress: -5)
            nudgeButton("plus", field: field, tap: 1, longPress: 5)
            // Snap this edge to wherever the preview playhead is right now.
            Button { setTime(field, to: playback.positionSeconds) } label: {
                Image(systemName: "arrow.down.to.line")
                    .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.accent))
                    .frame(width: 40, height: 40)
                    .background(theme.color(.accentWash)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set \(label.lowercased()) to playhead")
        }
    }

    // Tap ±1s; a still long-press ±5s (same simultaneous-gesture trick as the scrubber).
    private func nudgeButton(_ symbol: String, field: TimeField,
                             tap: TimeInterval, longPress: TimeInterval) -> some View {
        Button { adjust(field, by: tap) } label: {
            Image(systemName: symbol)
                .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
                .frame(width: 40, height: 40)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            adjust(field, by: longPress)
        })
        .accessibilityLabel("\(tap > 0 ? "Later" : "Earlier") by \(Int(abs(tap))) second")
        .accessibilityHint("Long press for \(Int(abs(longPress))) seconds")
    }

    private func adjust(_ field: TimeField, by delta: TimeInterval) {
        setTime(field, to: (field == .start ? start : end) + delta)
    }

    /// Clamps every edit so `0 ≤ start ≤ end − minLength` and `start + minLength ≤ end ≤ duration`.
    /// A running preview keeps looping its old range; the new range takes effect next Preview tap.
    private func setTime(_ field: TimeField, to value: TimeInterval) {
        switch field {
        case .start: start = max(0, min(value, end - Self.minLength))
        case .end:   end = min(duration, max(value, start + Self.minLength))
        }
    }

    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func save() {
        let text = excerpt
        if let existing {
            clips.updateClip(existing, start: start, end: end, text: text,
                             note: note.isEmpty ? nil : note)
        } else if let episode {
            clips.makeClipExact(episode: episode, start: start, end: end, text: text,
                                note: note.isEmpty ? nil : note, needsReview: false)
        }
        dismiss()
    }
}
```

- [ ] **Step 2: Swap the two existing call sites**

In `Onda/Clips/ClipsView.swift` line 84, change:

```swift
            .sheet(item: $editing) { ClipEditSheet(clip: $0) }
```

to:

```swift
            .sheet(item: $editing) { ClipReviewSheet(clip: $0) }
```

In `Onda/Player/TranscriptView.swift` lines 132–138, change the sheet content from `ClipEditSheet(episode:requestedStart:requestedEnd:)` to:

```swift
            .sheet(isPresented: $showClipSheet, onDismiss: resetSelection, content: {
                if let r = selectionRange {
                    ClipReviewSheet(episode: episode,
                                    start: cueVMs[r.lowerBound].start,
                                    end: cueVMs[r.upperBound].end)
                }
            })
```

- [ ] **Step 3: Delete the old sheet and regenerate the project**

```sh
rm Onda/Clips/ClipEditSheet.swift
xcodegen generate
```

- [ ] **Step 4: Build + run the clip suites**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" 2>&1 | tail -5
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/ClipServiceTests \
  -only-testing:OndaTests/ClipTextSnapshotTests 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`, both suites pass. If the build fails with `ClipEditSheet` not found anywhere else, grep for stragglers: `grep -rn "ClipEditSheet" Onda OndaTests OndaUITests` (should return nothing).

- [ ] **Step 5: Commit**

```sh
git add -A Onda/Clips/ClipReviewSheet.swift Onda/Clips/ClipEditSheet.swift \
  Onda/Clips/ClipsView.swift Onda/Player/TranscriptView.swift Onda.xcodeproj
git commit -m "feat: ClipReviewSheet with looping preview + time editing, replacing ClipEditSheet"
```

---

### Task 5: In-player capture — scissors icon + live banner in `NowPlayingView`

**Files:**
- Modify: `Onda/Player/NowPlayingView.swift`
- Create: `OndaTests/ClipCaptureMathTests.swift`

**Interfaces:**
- Consumes: `ClipReviewSheet(episode:start:end:)` and `ClipReviewSheet.minLength` (Task 4); `playback.positionSeconds`.
- Produces: `NowPlayingView.clipLookback` (`5`), `static func clipStartValue(position:) -> TimeInterval`, `static func clipEnd(start:position:) -> TimeInterval` (pure clamp helpers, unit-tested).

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/ClipCaptureMathTests.swift`:

```swift
//  ClipCaptureMathTests.swift
import XCTest
@testable import Onda

@MainActor
final class ClipCaptureMathTests: XCTestCase {
    func test_clipStart_looksBack5s_flooredAtZero() {
        XCTAssertEqual(NowPlayingView.clipStartValue(position: 100), 95)
        XCTAssertEqual(NowPlayingView.clipStartValue(position: 3), 0, "never before the episode start")
    }

    func test_clipEnd_isTapPosition_butAtLeastMinLengthAfterStart() {
        XCTAssertEqual(NowPlayingView.clipEnd(start: 95, position: 130), 130)
        // Tapping End immediately after Start: enforce the 1s minimum length.
        XCTAssertEqual(NowPlayingView.clipEnd(start: 95, position: 95.2),
                       95 + ClipReviewSheet.minLength)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/ClipCaptureMathTests 2>&1 | tail -20
```

(`xcodegen generate` first — a new test file was added.) Expected: **build failure** — no members `clipStartValue` / `clipEnd`.

- [ ] **Step 3: Implement capture in `NowPlayingView`**

All edits in `Onda/Player/NowPlayingView.swift`.

**(a)** Add state and a pending-clip item type. After `@State private var jumpText = ""` (line 15), add:

```swift
    // In-progress clip capture: set when the user taps the scissors, cleared on End/cancel.
    @State private var clipStart: TimeInterval?
    @State private var pendingClip: PendingClip?

    /// A captured-but-unsaved range handed to the Clip Review sheet (Cancel discards it).
    struct PendingClip: Identifiable {
        let id = UUID()
        let episode: Episode
        let start: TimeInterval
        let end: TimeInterval
    }
```

**(b)** Add the scissors button to `header`, before the `SleepTimerMenu()` line:

```swift
    private var header: some View {
        HStack(spacing: 2) {
            Button { dismiss() } label: { headerIcon("chevron.down") }
            Spacer()
            Button { toggleClipCapture() } label: { headerIcon("scissors") }
                .foregroundStyle(clipStart == nil ? theme.color(.textSecondary)
                                                  : theme.color(.accent))
                .disabled(ep == nil)
                .accessibilityLabel(clipStart == nil ? "Start clip" : "End clip")
                .accessibilityIdentifier("clip-button")
            SleepTimerMenu()
            Button { showTranscript = true } label: { headerIcon("text.quote") }
                .accessibilityIdentifier("transcript-button")
            Button { showQueue = true } label: { headerIcon("list.bullet") }
            Button { showSettings = true } label: { headerIcon("ellipsis") }
        }
        .foregroundStyle(theme.color(.textSecondary))
    }
```

**(c)** Replace the existing top overlay (currently only the back-to-transcript button) so the clip banner takes precedence while capturing:

```swift
        .overlay(alignment: .top) {
            if let s = clipStart {
                clipBanner(startedAt: s)
            } else if playback.returnToTranscriptEpisode != nil {
                BackToTranscriptButton {
                    playback.clearTranscriptReturn()
                    showTranscript = true
                }
            }
        }
```

**(d)** Next to the existing `.animation`/`.sheet` modifiers on the body, add:

```swift
        .animation(.easeOut(duration: 0.2), value: clipStart == nil)
        // An episode change (queue advance, new play) invalidates an in-progress capture:
        // its start time belongs to the previous episode's timeline.
        .onChange(of: ep?.guid) { _, _ in clipStart = nil }
        .sheet(item: $pendingClip) { p in
            ClipReviewSheet(episode: p.episode, start: p.start, end: p.end)
        }
```

**(e)** Add the banner view and capture logic (place after the `about(_:)` function, before the closing brace of the main `struct` body):

```swift
    /// Live capture banner: running clip length, End Clip, and a discard ×. White-on-accentStrong
    /// for AA contrast (CLAUDE.md); same top placement as BackToTranscriptButton.
    private func clipBanner(startedAt s: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").scaledFont(13, weight: .bold)
            Text("Clipping · \(timeStr(max(0, playback.positionSeconds - s)))")
                .scaledFont(13.5, weight: .bold).monospacedDigit()
            Button("End Clip") { endClip() }
                .scaledFont(13.5, weight: .bold)
                .accessibilityIdentifier("end-clip-button")
            Button { clipStart = nil } label: {
                Image(systemName: "xmark").scaledFont(12, weight: .bold)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel clip")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color(.accentStrong)).brutalBorder(width: 2).hardShadow(offset: 3)
        .padding(.top, 112)   // clear the pinned header row
        .transition(.move(edge: .top).combined(with: .opacity))
    }
```

**(f)** Add the capture math + actions to the existing `extension NowPlayingView` (the one holding `parseTimecode`, near line 309):

```swift
    /// Reaction-time cushion: a Start tap marks this many seconds before the tap.
    static let clipLookback: TimeInterval = 5

    /// Where a Start tap begins the clip: 5s before the tap, floored at the episode start.
    static func clipStartValue(position: TimeInterval) -> TimeInterval {
        max(0, position - clipLookback)
    }

    /// Where an End tap closes the clip: the tap position, but at least minLength after start.
    static func clipEnd(start: TimeInterval, position: TimeInterval) -> TimeInterval {
        max(position, start + ClipReviewSheet.minLength)
    }

    /// Scissors tap: starts a capture, or ends the in-progress one.
    func toggleClipCapture() {
        if clipStart == nil {
            clipStart = Self.clipStartValue(position: playback.positionSeconds)
        } else {
            endClip()
        }
    }

    /// Ends the in-progress capture and opens the review sheet with the pending range.
    func endClip() {
        guard let ep, let s = clipStart else { return }
        clipStart = nil
        pendingClip = PendingClip(episode: ep, start: s,
                                  end: Self.clipEnd(start: s, position: playback.positionSeconds))
    }
```

- [ ] **Step 4: Run the new tests + full unit suite**

```sh
xcrun simctl create onda-clips-sim "iPhone 17" 2>/dev/null || true
UDID=$(xcrun simctl list devices | awk -F '[()]' '/onda-clips-sim /{print $2; exit}')
DD=.dd-clips
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests/ClipCaptureMathTests 2>&1 | tail -10
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" \
  -derivedDataPath "$DD" -only-testing:OndaTests 2>&1 | tail -10
```

Expected: `ClipCaptureMathTests` passes; the full `OndaTests` bundle passes. (If `SpeechEngineReproTests` hangs, it self-skips only when the sim has a speech TCC record — it is guarded to skip without one per repo history; if it does hang, exclude it with `-skip-testing:OndaTests/SpeechEngineReproTests` and note that in the report.)

- [ ] **Step 5: Run SwiftLint**

```sh
swiftlint lint --quiet
```

Expected: no violations in the touched files (fix any that appear).

- [ ] **Step 6: Commit**

```sh
git add Onda/Player/NowPlayingView.swift OndaTests/ClipCaptureMathTests.swift Onda.xcodeproj
git commit -m "feat: start/end clip capture from the fullscreen player"
```

---

### Task 6: End-to-end verification in the simulator

**Files:** none (verification only)

- [ ] **Step 1: Drive the app** — use the project's `verify` skill (build, launch, and drive Onda in the iOS Simulator) to walk the happy path:

1. Play an episode → open the fullscreen player.
2. Tap the scissors → banner appears with a ticking length; scissors turns accent-colored.
3. Wait ~10s, tap **End Clip** → `ClipReviewSheet` opens; main playback pauses.
4. Tap **Preview Clip** → audio plays from ~5s before the Start tap and loops at the end bound.
5. Nudge Start −/+, tap the End timecode and type `12:34`-style values → excerpt updates, clamps hold.
6. **Save** → sheet closes, playback resumes at the pre-sheet position.
7. Clips tab → the new clip is listed; tapping it opens the same review sheet with times editable.

- [ ] **Step 2: Report** — screenshots of the banner and the review sheet, plus any deviations found. Fix-forward anything broken before declaring done (superpowers:verification-before-completion).

---

## Self-Review Notes

- **Spec coverage:** look-back capture (T5), banner with live length/End/cancel (T5), pending-unsaved range (T5→T4), review sheet with excerpt/preview/nudge/typed-timecode/set-to-playhead/note (T4), looping episode-aware preview with snapshot/restore (T3), exact-times save + reindex (T2), non-expanding text (T1), call-site replacement incl. transcript + clips list (T4), episode-change discard (T5d), no auto-download on preview (T3), `quickClip` untouched (no task edits it). ✅
- **Type consistency:** `ClipReviewSheet.minLength` referenced by T5's `clipEnd`; `previewRange(episode:start:end:)` signature identical in T3 code and T4 sheet; `makeClipExact`/`updateClip` signatures match between T2 and T4. ✅
- **Known judgment calls:** running preview keeps looping the *old* range after a nudge (spec: "range follows on next Preview"); `endClipPreview` with no prior episode leaves the clip's episode loaded paused; banner replaces (takes precedence over) the back-to-transcript button while capturing.
