# Onda Plan 10: On-Device AI Auto-Chapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate chapter markers on-device (via Apple's Foundation Models framework — no network calls) for episodes whose feed ships no chapters at all, once a transcript exists to generate from. On-demand only, mirroring the existing "Transcribe episode" affordance. Never overrides feed-provided chapters; generated chapters are clearly distinguishable from feed chapters and never claim ad detection.

**Architecture:** New `ChapterGenerating` protocol (mirrors `AudioTranscribing`'s testability shape) with a real `FoundationModelsChapterGenerator` implementation gated `@available`/`canImport(FoundationModels)` behind an availability check, and a `ChapterGenerationService` (`@MainActor @Observable`, same shape as `TranscriptService`) that persists results as `Chapter` rows tagged `source: "generated"`. UI: an empty-chapters affordance in `NowPlayingView`, same pattern as `TranscriptView`'s "Transcribe episode" button.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, FoundationModels (iOS 26+, Apple Intelligence-capable hardware), XCTest.

## Global Constraints

- Plan 1 Global Constraints apply verbatim (iOS 17, SwiftUI+SwiftData only, MV pattern, brutal style).
- No network calls, ever, for this feature — Foundation Models runs entirely on-device. If `FoundationModels`/Apple Intelligence isn't available, the feature is simply absent (same posture as `SpeechTranscriberEngine` on pre-iOS-26 devices) — no cloud fallback.
- Only offered when `episode.chapters.isEmpty` (never overrides feed-provided chapters) **and** a transcript exists.
- Generated `Chapter` rows always have `isAd == false` — this is topic segmentation, not ad detection, which stays out of scope.
- **Open risk carried from the spec:** the exact `FoundationModels` API surface is very new; verify method/type names against the SDK actually installed when implementing Task 2, and adjust names if Apple's shipped API differs from what's drafted here — the protocol boundary (`ChapterGenerating`) means every other task is unaffected by that adjustment.

**Depends on:** Plans 1–7 merged (v0.3.0+) for `Chapter`/`Transcript`. Independent of Plans 8, 9, 11.

---

## File Structure

```
Onda/
  Models/
    Chapter.swift              — MODIFY: source field
    ModelSchema.swift          — unchanged (Chapter already registered)
  Playback/
    ChapterFetcher.swift       — MODIFY: ParsedChapter gains source (reused by generation too)
    ChapterGenerating.swift    — NEW: protocol + FoundationModelsChapterGenerator
    ChapterGenerationService.swift — NEW: @Observable service
  Player/
    NowPlayingView.swift       — MODIFY: "Generate chapters" affordance in chapterList's empty case
  OndaApp.swift                — MODIFY: inject ChapterGenerationService
OndaTests/
  ChapterGenerationServiceTests.swift
```

---

### Task 1: `Chapter.source` + `ParsedChapter.source`

**Files:**
- Modify: `Onda/Models/Chapter.swift`, `Onda/Playback/ChapterFetcher.swift`
- Test: `OndaTests/ModelTests.swift` (append), `OndaTests/ChapterFetcherTests.swift` (verify unaffected)

**Interfaces:**
- Produces: `Chapter.source: String` (new stored property, `"feed"` default), `Chapter.init(title:startTime:isAd:source:)` with `source: String = "feed"` so existing call sites (`ChapterFetcher`-derived construction, existing tests) compile unchanged. `ParsedChapter` gains `let source: String = "feed"` (constant default — `ChapterFetcher.decode` only ever parses feed chapters, so it always produces `"feed"`).

- [ ] **Step 1: Write failing test** (append to `OndaTests/ModelTests.swift`)

```swift
    func test_chapter_defaultsToFeedSource() throws {
        let ctx = try inMemoryContext()
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        let feedChapter = Chapter(title: "Intro", startTime: 0, isAd: false)
        let generatedChapter = Chapter(title: "AI: Setup", startTime: 120, isAd: false, source: "generated")
        feedChapter.episode = ep; ep.chapters.append(feedChapter)
        generatedChapter.episode = ep; ep.chapters.append(generatedChapter)
        ctx.insert(ep); ctx.insert(feedChapter); ctx.insert(generatedChapter)
        try ctx.save()
        XCTAssertEqual(feedChapter.source, "feed")
        XCTAssertEqual(generatedChapter.source, "generated")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ModelTests`
Expected: FAIL — `extra argument 'source' in call` / `value has no member 'source'`.

- [ ] **Step 3: Implement**

`Onda/Models/Chapter.swift`:

```swift
//  Chapter.swift
import Foundation
import SwiftData

@Model
final class Chapter {
    var title: String
    var startTime: TimeInterval
    var isAd: Bool
    var source: String        // "feed" | "generated"
    var episode: Episode?

    init(title: String, startTime: TimeInterval, isAd: Bool = false, source: String = "feed") {
        self.title = title
        self.startTime = startTime
        self.isAd = isAd
        self.source = source
    }
}
```

`Onda/Playback/ChapterFetcher.swift` — add `source` to `ParsedChapter` (used only for feed-parsed chapters, so it's a fixed constant, not a parameter):

```swift
struct ParsedChapter { let title: String; let startTime: TimeInterval; let isAd: Bool; let source = "feed" }
```

- [ ] **Step 4: Run to verify pass** — Expected: `ModelTests` PASS; run `-only-testing:OndaTests/ChapterFetcherTests` too — Expected: unaffected, still PASS (the struct's existing 3-arg construction still compiles since `source` has no parameter, it's a fixed default member).
- [ ] **Step 5: Commit** — `git add Onda/Models/Chapter.swift Onda/Playback/ChapterFetcher.swift OndaTests/ModelTests.swift && git commit -m "feat: Chapter.source (feed|generated) distinguishes AI-generated chapters"`

---

### Task 2: `ChapterGenerating` protocol + `FoundationModelsChapterGenerator`

**Files:**
- Create: `Onda/Playback/ChapterGenerating.swift`

**Interfaces:**
- Produces:
  - `enum ChapterGenerationError: Error { case unavailable, noTranscript }`
  - `protocol ChapterGenerating: Sendable { func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter] }`
  - `@available(iOS 26, *) final class FoundationModelsChapterGenerator: ChapterGenerating` — `static var isAvailable: Bool` (true only when `SystemLanguageModel.default.availability == .available`); `generateChapters(transcriptText:duration:)` prompts a `LanguageModelSession` for 3–8 chapter markers (title + start-time-in-seconds) spanning the transcript, using `@Generable` structured output, and maps results to `ParsedChapter(title:startTime:isAd: false)` — never sets `isAd: true` regardless of model output (topic segmentation only, not ad detection).

- [ ] **Step 1: Implement**

```swift
//  ChapterGenerating.swift
import Foundation

enum ChapterGenerationError: Error { case unavailable, noTranscript }

protocol ChapterGenerating: Sendable {
    func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter]
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
final class FoundationModelsChapterGenerator: ChapterGenerating {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct GeneratedChapters {
        @Guide(description: "3 to 8 chapter markers spanning the whole episode, ordered by time")
        let chapters: [GeneratedChapter]
    }

    @Generable
    struct GeneratedChapter {
        @Guide(description: "Short, descriptive chapter title (a few words)")
        let title: String
        @Guide(description: "Start time of this chapter in seconds from the beginning of the episode")
        let startTimeSeconds: Double
    }

    func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter] {
        guard Self.isAvailable else { throw ChapterGenerationError.unavailable }
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChapterGenerationError.noTranscript
        }
        let session = LanguageModelSession()
        let prompt = """
        This is the transcript of a podcast episode that runs \(Int(duration)) seconds long. \
        Propose 3 to 8 chapter markers with short titles and start times (in seconds from the \
        start), spanning the whole episode from near 0 to near \(Int(duration)).

        Transcript:
        \(transcriptText.prefix(12_000))
        """
        let result = try await session.respond(to: prompt, generating: GeneratedChapters.self)
        return result.content.chapters
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { ParsedChapter(title: $0.title, startTime: $0.startTimeSeconds, isAd: false) }
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `xcodegen generate -q && xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED. (This file is gated `#if canImport(FoundationModels)` / `@available(iOS 26, *)`, same posture as `SpeechTranscriberEngine` — it is excluded entirely on toolchains without the framework, and has no direct XCTest coverage for the same reason: no fake exists for the real on-device model. `ChapterGenerationService` in Task 3 is tested entirely through the `ChapterGenerating` protocol with a stub.)

- [ ] **Step 3: Commit** — `"feat: FoundationModelsChapterGenerator (on-device, no network, gated to Apple Intelligence availability)"`

---

### Task 3: `ChapterGenerationService`

**Files:**
- Create: `Onda/Playback/ChapterGenerationService.swift`
- Test: `OndaTests/ChapterGenerationServiceTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class ChapterGenerationService`
  - `init(modelContext: ModelContext, generator: ChapterGenerating?, transcriptText: @escaping (Episode) -> String?)`
  - `var lastFailure: [String: String]` (guid → human-readable reason), `var isGenerating: [String: Bool]`
  - `func canGenerate(_ episode: Episode) -> Bool` — `generator != nil && episode.chapters.isEmpty && transcriptText(episode) != nil`
  - `@discardableResult func generate(for episode: Episode) async -> [Chapter]?` — calls the generator with the joined transcript text and episode duration, persists each result as a `Chapter(title:startTime:isAd: false, source: "generated")` linked to the episode, saves, and returns the new chapters (`nil` on failure, with `lastFailure[guid]` set).

- [ ] **Step 1: Write failing tests**

```swift
//  ChapterGenerationServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubGenerator: ChapterGenerating {
    var result: Result<[ParsedChapter], Error>
    func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter] {
        try result.get()
    }
}

@MainActor
final class ChapterGenerationServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }
    private func episode(in ctx: ModelContext) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 1800,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_canGenerate_requiresNoExistingChaptersAndATranscript() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .success([]))
        let withText = ChapterGenerationService(modelContext: ctx, generator: stub, transcriptText: { _ in "hello" })
        XCTAssertTrue(withText.canGenerate(ep))

        let noText = ChapterGenerationService(modelContext: ctx, generator: stub, transcriptText: { _ in nil })
        XCTAssertFalse(noText.canGenerate(ep))

        ep.chapters.append(Chapter(title: "Existing", startTime: 0))
        XCTAssertFalse(withText.canGenerate(ep), "never offered when the feed already has chapters")
    }

    func test_generate_persistsChaptersTaggedGenerated_neverAd() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .success([
            ParsedChapter(title: "Intro", startTime: 0, isAd: true),   // model can't claim ad — must be forced false
            ParsedChapter(title: "Main topic", startTime: 300, isAd: false),
        ]))
        let svc = ChapterGenerationService(modelContext: ctx, generator: stub, transcriptText: { _ in "a transcript" })
        let chapters = await svc.generate(for: ep)
        XCTAssertEqual(chapters?.count, 2)
        XCTAssertEqual(ep.chapters.count, 2)
        XCTAssertTrue(ep.chapters.allSatisfy { $0.source == "generated" && $0.isAd == false })
    }

    func test_generate_failure_setsLastFailure_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let stub = StubGenerator(result: .failure(ChapterGenerationError.unavailable))
        let svc = ChapterGenerationService(modelContext: ctx, generator: stub, transcriptText: { _ in "text" })
        let chapters = await svc.generate(for: ep)
        XCTAssertNil(chapters)
        XCTAssertNotNil(svc.lastFailure["g"])
        XCTAssertTrue(ep.chapters.isEmpty)
    }

    func test_generate_noGenerator_returnsNil() async throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx)
        let svc = ChapterGenerationService(modelContext: ctx, generator: nil, transcriptText: { _ in "text" })
        let chapters = await svc.generate(for: ep)
        XCTAssertNil(chapters)
    }
}
```

- [ ] **Step 2: Run to verify failure** — Expected: `cannot find 'ChapterGenerationService'`.

- [ ] **Step 3: Implement**

```swift
//  ChapterGenerationService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ChapterGenerationService {
    private let modelContext: ModelContext
    private let generator: ChapterGenerating?
    private let transcriptText: (Episode) -> String?

    var isGenerating: [String: Bool] = [:]
    var lastFailure: [String: String] = [:]

    init(modelContext: ModelContext, generator: ChapterGenerating?,
         transcriptText: @escaping (Episode) -> String?) {
        self.modelContext = modelContext
        self.generator = generator
        self.transcriptText = transcriptText
    }

    func canGenerate(_ episode: Episode) -> Bool {
        generator != nil && episode.chapters.isEmpty && transcriptText(episode) != nil
    }

    @discardableResult
    func generate(for episode: Episode) async -> [Chapter]? {
        guard let generator, let text = transcriptText(episode) else { return nil }
        let guid = episode.guid
        isGenerating[guid] = true
        defer { isGenerating[guid] = false }
        do {
            lastFailure[guid] = nil
            let parsed = try await generator.generateChapters(transcriptText: text, duration: episode.duration)
            guard !parsed.isEmpty else {
                lastFailure[guid] = "Couldn't find distinct chapters in this episode."
                return nil
            }
            var built: [Chapter] = []
            built.reserveCapacity(parsed.count)
            for pc in parsed {
                let chapter = Chapter(title: pc.title, startTime: pc.startTime, isAd: false, source: "generated")
                chapter.episode = episode
                modelContext.insert(chapter)
                built.append(chapter)
            }
            episode.chapters.append(contentsOf: built)
            try? modelContext.save()
            return built
        } catch {
            lastFailure[guid] = "Couldn't generate chapters: \(error.localizedDescription)"
            return nil
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — Expected: 4 tests PASS.
- [ ] **Step 5: Commit** — `"feat: ChapterGenerationService (on-demand, persists generated chapters, isAd always false)"`

---

### Task 4: "Generate chapters" affordance in `NowPlayingView`

**Files:**
- Modify: `Onda/Player/NowPlayingView.swift`, `Onda/OndaApp.swift`

**Interfaces:**
- `NowPlayingView.chapterList(_:)` gains an `else` branch (episode has no chapters) rendering a "Generate chapters" button when `chapterGen.canGenerate(ep)`, calling `await chapterGen.generate(for: ep)`, with a progress/failure state mirroring `TranscriptView`'s empty state. `OndaApp` builds and injects a `ChapterGenerationService` the same way it builds `TranscriptService`, passing `FoundationModelsChapterGenerator()` when available and a `transcriptText` closure that joins the episode's transcript cues.

- [ ] **Step 1: Implement** — in `NowPlayingView`, add `@Environment(ChapterGenerationService.self) private var chapterGen` and replace `chapterList(_:)`'s body:

```swift
    private func chapterList(_ ep: Episode) -> some View {
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
            } else if chapterGen.canGenerate(ep) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await chapterGen.generate(for: ep) }
                    } label: {
                        Text(chapterGen.isGenerating[ep.guid] == true ? "Generating…" : "Generate chapters")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.color(.accent))
                    }
                    .disabled(chapterGen.isGenerating[ep.guid] == true)
                    if let failure = chapterGen.lastFailure[ep.guid] {
                        Text(failure).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }.frame(maxWidth: 280)
            }
        }
    }
```

- [ ] **Step 2: Wire in `OndaApp.init()`** — after building `_transcripts`, add:

```swift
            let chapterGenerator: ChapterGenerating? = {
                if #available(iOS 26, *), FoundationModelsChapterGenerator.isAvailable {
                    return FoundationModelsChapterGenerator()
                }
                return nil
            }()
            _chapterGen = State(initialValue: ChapterGenerationService(
                modelContext: c.mainContext, generator: chapterGenerator,
                transcriptText: { ep in
                    let cues = ep.transcript?.cues.sorted { $0.startTime < $1.startTime } ?? []
                    let joined = cues.map(\.text).joined(separator: " ")
                    return joined.isEmpty ? nil : joined
                }))
```

Add the matching `@State private var chapterGen: ChapterGenerationService` property declaration and `.environment(chapterGen)` in `body`.

- [ ] **Step 3: Build + full test run**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 4: Manual smoke (user, Apple Intelligence-capable device/simulator only)** — open an episode whose feed ships no chapters but does have a transcript; tap "Generate chapters"; confirm chapters appear, are tappable/seekable, and never show an ad banner for them. On a device without Apple Intelligence, confirm the empty-chapters state is unchanged (no button shown) — same as v1 behavior today.

- [ ] **Step 5: Commit** — `"feat: on-demand AI chapter generation UI in Now Playing"`

---

## Self-Review

- **Spec coverage:** on-demand only, gated to Apple Intelligence availability, no network ✓; only offered with zero feed chapters + existing transcript ✓; `source: "generated"` tag + `isAd` always false ✓; empty state unaffected when unavailable (mirrors v1 fallback) ✓.
- **Placeholder scan:** none — full code in every step; the one open item (exact `FoundationModels` API surface) is called out explicitly as a risk in Global Constraints, not hidden as a TBD, and is isolated behind the `ChapterGenerating` protocol so it can't leak into other tasks.
- **Type consistency:** `ChapterGenerating.generateChapters(transcriptText:duration:)`, `ParsedChapter(title:startTime:isAd:)` (+ fixed `source` member), `Chapter(title:startTime:isAd:source:)`, `ChapterGenerationService.canGenerate/generate/isGenerating/lastFailure` used identically across Tasks 2–4.

## Post-review note: feed/generated coexistence policy

ChapterFetcher currently has no production call site — `Episode.chaptersURL` is stored during feed parsing but never fetched. When feed-chapter fetching is wired into refresh, arriving feed chapters MUST first delete any existing `source == "generated"` chapters for that episode (feed wins), then insert the fetched ones. `ChapterGenerationService.generate(for:)`'s `chapters.isEmpty` guard is the second line of defense: it prevents generated chapters from ever being added alongside feed chapters, but it cannot retroactively remove generated chapters once real feed chapters arrive — the refresh-side delete is the primary mechanism.
