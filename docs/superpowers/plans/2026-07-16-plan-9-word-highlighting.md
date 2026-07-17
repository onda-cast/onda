# Onda Plan 9: Word-Level Transcript Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real per-word highlighting in the transcript view, but only for on-device transcripts, where `SpeechAnalyzer` provides genuine per-word timing. Published transcripts (WebVTT/SRT/PC2.0 JSON — almost always cue-level only) keep today's whole-cue highlight. No interpolation of fake word timing for published cues.

**Architecture:** `TranscriptCue` gains an optional `words: [WordTiming]?`, populated only on the `source == "ondevice"` path. `SpeechTranscriberEngine` already iterates `result.text.runs` for each recognized span but currently only reads `.first`'s `audioTimeRange` to time the whole cue — it changes to capture every run (each run already carries its own `audioTimeRange`) as a `WordTiming`, and derives the cue's own start/end from the min/max of those. `TranscriptView` reuses the existing generic `ActiveCue.index` (already tested) to find the active word within the active cue, and renders concatenated per-word-styled `Text` segments instead of one plain `Text` when word timing exists.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Speech/AVFoundation (iOS 26+), XCTest.

## Global Constraints

- Plan 1 Global Constraints apply verbatim (iOS 17, SwiftUI+SwiftData only, MV pattern, brutal style).
- Word timing is real timing only — never interpolate/guess word position within a published (cue-level-only) transcript. `words` stays `nil` for `source == "published"`.
- Canonical timeline: `WordTiming.startTime`/`endTime` are feed-seconds, same as `TranscriptCue`.

**Depends on:** Plans 1–7 merged (v0.3.0+). Independent of Plans 8, 10, 11.

---

## File Structure

```
Onda/
  Models/
    Transcript.swift          — MODIFY: WordTiming struct, TranscriptCue.words
  Transcription/
    ParsedCue.swift            — MODIFY: words field
    AudioTranscribing.swift    — MODIFY: SpeechTranscriberEngine captures per-run word timing
    TranscriptService.swift    — MODIFY: persist(cues:) carries words through
  Player/
    TranscriptView.swift       — MODIFY: per-word highlight when cue.words present
OndaTests/
  TranscriptServiceTests.swift — MODIFY: word-timing pass-through test
```

---

### Task 1: `WordTiming` + `TranscriptCue.words` + pass-through persistence

**Files:**
- Modify: `Onda/Models/Transcript.swift`, `Onda/Transcription/ParsedCue.swift`, `Onda/Transcription/TranscriptService.swift`
- Test: `OndaTests/TranscriptServiceTests.swift`

**Interfaces:**
- Produces:
  - `struct WordTiming: Codable, Equatable, Sendable { let text: String; let startTime: TimeInterval; let endTime: TimeInterval }`
  - `TranscriptCue.words: [WordTiming]?` (new stored property, defaults `nil`), and `TranscriptCue.init(startTime:endTime:text:speaker:words:)` with `words: [WordTiming]? = nil` so existing call sites compile unchanged.
  - `ParsedCue.words: [WordTiming]?` (defaults `nil` via a new memberwise-compatible initializer parameter with a default), carried into the persisted `TranscriptCue` by `TranscriptService.persist(cues:for:source:)`.

- [ ] **Step 1: Write failing test** (append to `TranscriptServiceTests.swift`)

```swift
    func test_persist_carriesWordTimingThrough_whenPresent() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let words = [WordTiming(text: "on", startTime: 0, endTime: 0.3),
                     WordTiming(text: "device", startTime: 0.3, endTime: 0.9)]
        let cues = [ParsedCue(startTime: 0, endTime: 0.9, text: "on device", speaker: nil, words: words)]
        let tr = svc.persist(cues: cues, for: ep, source: "ondevice")
        XCTAssertEqual(tr.cues.first?.words, words)
    }

    func test_persist_wordsNil_whenSourceIsPublished() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let cues = [ParsedCue(startTime: 0, endTime: 3, text: "Hello there.", speaker: nil)]
        let tr = svc.persist(cues: cues, for: ep, source: "published")
        XCTAssertNil(tr.cues.first?.words)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/TranscriptServiceTests`
Expected: FAIL — `extra argument 'words' in call` / `type '[WordTiming]' has no member` (no such type yet).

- [ ] **Step 3: Implement**

`Onda/Models/Transcript.swift` — replace the `TranscriptCue` class body:

```swift
//  Transcript.swift
import Foundation
import SwiftData

@Model
final class Transcript {
    var source: String       // "published" | "ondevice"
    var language: String
    var episode: Episode?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptCue.transcript)
    var cues: [TranscriptCue] = []

    init(source: String, language: String) {
        self.source = source
        self.language = language
    }
}

struct WordTiming: Codable, Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

@Model
final class TranscriptCue {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var words: [WordTiming]?   // real per-word timing; only ever set for source == "ondevice"
    var transcript: Transcript?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?,
         words: [WordTiming]? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}
```

`Onda/Transcription/ParsedCue.swift`:

```swift
//  ParsedCue.swift
import Foundation

struct ParsedCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?
    let words: [WordTiming]?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?,
         words: [WordTiming]? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}
```

`Onda/Transcription/TranscriptService.swift` — in `persist(cues:for:source:)`, change cue construction:

```swift
        for pc in cues {
            let cue = TranscriptCue(startTime: pc.startTime, endTime: pc.endTime,
                                    text: pc.text, speaker: pc.speaker, words: pc.words)
            modelContext.insert(cue)
            built.append(cue)
        }
```

- [ ] **Step 4: Run to verify pass** — Expected: all `TranscriptServiceTests` PASS (existing + 2 new).
- [ ] **Step 5: Commit** — `git add Onda/Models/Transcript.swift Onda/Transcription OndaTests/TranscriptServiceTests.swift && git commit -m "feat: WordTiming + TranscriptCue.words, carried through persist for on-device transcripts"`

---

### Task 2: `SpeechTranscriberEngine` captures per-run word timing

**Files:**
- Modify: `Onda/Transcription/AudioTranscribing.swift`

**Interfaces:**
- `SpeechTranscriberEngine.transcribe(fileURL:progress:)` now maps **every** run in `result.text.runs` (not just `.first`) to a `WordTiming`, and derives the cue's own `startTime`/`endTime` from the first/last run's range instead of only the first. Not independently unit-testable (no fake for the real `Speech` framework — same as today, where this file has no direct XCTest coverage and is exercised only through the `AudioTranscribing` protocol via `StubEngine` in `TranscriptServiceTests`). Task 1's tests already cover the persistence path this feeds into.

- [ ] **Step 1: Implement** — replace the body of the `resultsTask` closure in `SpeechTranscriberEngine.transcribe`:

```swift
        let resultsTask = Task { () -> [ParsedCue] in
            var cues: [ParsedCue] = []
            for try await result in transcriber.results {
                let runs = Array(result.text.runs)
                guard !runs.isEmpty else { continue }
                let words: [WordTiming] = runs.compactMap { run in
                    guard let range = run.audioTimeRange else { return nil }
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return WordTiming(text: text, startTime: range.start.seconds, endTime: range.end.seconds)
                }
                let text = String(result.text.characters)
                let start = words.first?.startTime ?? 0
                let end = words.last?.endTime ?? start
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    cues.append(ParsedCue(startTime: start, endTime: end, text: text, speaker: nil,
                                          words: words.isEmpty ? nil : words))
                    if total > 0 { progress(min(1, end / total)) }
                }
            }
            return cues
        }
```

- [ ] **Step 2: Build** (device or simulator with the `Speech` module available — this code is gated `#if canImport(Speech)` / `@available(iOS 26, *)` and only compiles on those toolchains; on a simulator/toolchain without it, this file is excluded and the build is unaffected).

Run: `xcodegen generate -q && xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit** — `"feat: SpeechTranscriberEngine emits per-run word timing"`

---

### Task 3: Per-word highlighting in `TranscriptView`

**Files:**
- Modify: `Onda/Player/TranscriptView.swift`

**Interfaces:**
- `TranscriptView.CueVM` gains `words: [WordTiming]?`. `snapshotCues()` copies it from `TranscriptCue.words`. A new private computed helper `activeWordIndex(for cue: CueVM) -> Int?` returns `ActiveCue.index(at: playback.positionSeconds, cues: (cue.words ?? []).map { ($0.startTime, $0.endTime) })` when `cue.words` is non-nil and non-empty, else `nil`. Rendering: when the cue is the active cue and has `words`, build the cue's `Text` by concatenating one styled segment per word (accent-on-active-word style mirrors the existing whole-cue active/inactive color split); otherwise render `Text(cue.text)` exactly as today.

- [ ] **Step 1: Implement** — in `TranscriptView.CueVM`, add the field:

```swift
    struct CueVM: Identifiable, Equatable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String?
        let words: [WordTiming]?
    }
```

In `snapshotCues()`:

```swift
        cueVMs = sorted.enumerated().map { i, c in
            CueVM(id: i, start: c.startTime, end: c.endTime, text: c.text, speaker: c.speaker, words: c.words)
        }
```

Add a helper and a styled-text builder, and use it in `transcriptList`:

```swift
    private func activeWordIndex(for cue: CueVM) -> Int? {
        guard let words = cue.words, !words.isEmpty else { return nil }
        return ActiveCue.index(at: playback.positionSeconds, cues: words.map { ($0.startTime, $0.endTime) })
    }

    private func styledCueText(_ cue: CueVM, isActiveCue: Bool) -> Text {
        guard isActiveCue, let words = cue.words, !words.isEmpty else {
            return Text(cue.text)
        }
        let activeWord = activeWordIndex(for: cue)
        return words.enumerated().reduce(Text("")) { acc, pair in
            let (i, w) = pair
            let color = i == activeWord ? theme.color(.text) : theme.color(.textTertiary)
            let sep = i == 0 ? "" : " "
            return acc + Text(sep + w.text).foregroundStyle(color)
        }
    }
```

Replace the cue label's `Text(cue.text)` line in `transcriptList` (inside the `ForEach(cueVMs)` button label) with:

```swift
                                styledCueText(cue, isActiveCue: i == activeIndex)
                                    .font(.system(size: 16))
                                    .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
```

(The outer `.foregroundStyle` is now a no-op for word-timed active cues, since each word segment sets its own color, but stays correct as the fallback color for cues without `words`.)

- [ ] **Step 2: Build + full test run**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, all tests PASS (no new XCTest coverage needed here — `ActiveCue.index` is already generically tested in `ActiveCueTests.swift`, and this task only reuses it against a different tuple source).

- [ ] **Step 3: Manual smoke (user)** — on a device/build with `SpeechTranscriberEngine` available: transcribe a downloaded episode on-device, open its transcript, play, and confirm the active word highlights and advances within the active cue. Then open a show with a **published** transcript and confirm it still highlights whole-cue only (no word-level flicker/guessing).

- [ ] **Step 4: Commit** — `"feat: per-word transcript highlighting for on-device transcripts"`

---

## Self-Review

- **Spec coverage:** `words` only populated for `source == "ondevice"` ✓ (published path never sets it — Task 1's second test pins this); real per-run timing, not interpolation ✓; whole-cue fallback preserved for cues without `words` ✓.
- **Placeholder scan:** none — full code in every step; Task 2 explicitly explains why it has no direct XCTest (same limitation as the pre-existing `SpeechTranscriberEngine`, which also has no direct tests).
- **Type consistency:** `WordTiming(text:startTime:endTime:)`, `ParsedCue(..., words:)`, `TranscriptCue(..., words:)`, `CueVM.words`, `ActiveCue.index` signature all match across tasks.
