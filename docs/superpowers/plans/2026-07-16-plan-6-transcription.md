# Onda Plan 6: Transcription (Apple Speech) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give episodes a time-aligned transcript — sourced from a published Podcasting 2.0 transcript when available, or transcribed on-device with Apple Speech (iOS 26+) as a fallback — rendered as a follow-along transcript view (which doubles as captions) and made searchable across the library.

**Architecture:** `TranscriptParser` (pure) turns published VTT/SRT/JSON into cues. `SpeechTranscriberEngine` (iOS 26+, behind `AudioTranscribing`) transcribes downloaded audio into cues. `TranscriptService` (`@Observable`) chooses the source on-demand, persists a `Transcript` + `TranscriptCue` rows, and owns Speech authorization. `ActiveCue` (pure) maps playback position → highlighted cue. `TranscriptSearch` full-text-queries stored cues. All cue times are feed-seconds (canonical timeline), so highlight + tap-to-seek reuse `PlaybackManager`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Speech (`SpeechAnalyzer`/`SpeechTranscriber`, iOS 26+), XCTest.

## Global Constraints

- Deployment target iOS 17.0 (Plan 1 Global Constraints apply verbatim). On-device transcription is gated `@available(iOS 26, *)`; below that, only published transcripts exist.
- Cue times are **feed-seconds** (canonical timeline). Highlight and seek go through `PlaybackManager.positionSeconds` / `seek(toFraction:)`.
- Published transcripts are fetched **on-demand** (first transcript-view open), then cached in SwiftData.
- Transcript-based chapter/ad inference is **out of scope**.
- On-device transcription is **opt-in**, iOS 26+, **downloaded episodes only**; requires Speech authorization (`NSSpeechRecognitionUsageDescription`).
- `AudioTranscribing` is a protocol; no test performs real speech recognition.
- Visual language + services from Plans 1–5 (`PlaybackManager`, `DownloadManager`, brutal styles).

**Depends on:** Plans 1–5 complete.

---

## File Structure

```
Onda/
  Models/
    Transcript.swift          — @Model Transcript + @Model TranscriptCue
    ModelSchema.swift         — MODIFY: add the two types
    Episode.swift             — MODIFY: transcriptURL, transcriptType
  Networking/
    RSSFeedParser.swift       — MODIFY: capture <podcast:transcript>
  Transcription/
    ParsedCue.swift           — value type shared by parser + engine
    TranscriptParser.swift    — VTT / SRT / PC2.0-JSON → [ParsedCue] (pure)
    AudioTranscribing.swift   — protocol + SpeechTranscriberEngine (iOS 26+)
    TranscriptService.swift   — @Observable; choose source, persist, authorize
    ActiveCue.swift           — position → active cue index (pure)
    TranscriptSearch.swift    — full-text over TranscriptCue
  Player/
    TranscriptView.swift      — follow-along transcript sheet (captions)
    NowPlayingView.swift      — MODIFY: transcript button
  Library/
    LibrarySearchView.swift   — transcript search across subscriptions
    LibraryView.swift         — MODIFY: search entry point
OndaTests/
  TranscriptParserTests.swift
  ActiveCueTests.swift
  TranscriptServiceTests.swift
  TranscriptSearchTests.swift
OndaTests/Fixtures/
  transcript.vtt
  transcript.srt
  transcript_pc20.json
```

---

### Task 1: Transcript models + Episode/feed fields

**Files:**
- Create: `Onda/Models/Transcript.swift`
- Modify: `Onda/Models/ModelSchema.swift`, `Onda/Models/Episode.swift`, `Onda/Networking/RSSFeedParser.swift`
- Test: `OndaTests/ModelTests.swift` (append)

**Interfaces:**
- Produces:
  - `@Model Transcript { var source: String; var language: String; var episode: Episode?; var cues: [TranscriptCue] }`, `init(source: String, language: String)`
  - `@Model TranscriptCue { var startTime: TimeInterval; var endTime: TimeInterval; var text: String; var speaker: String?; var transcript: Transcript? }`, `init(startTime:endTime:text:speaker:)`
  - `Episode.transcriptURL: URL?`, `Episode.transcriptType: String?`, `Episode.transcript: Transcript?`
  - `ParsedFeed`/`ParsedEpisode` gain `transcriptURL: URL?`, `transcriptType: String?`

- [ ] **Step 1: Write the failing model test**

Append to `OndaTests/ModelTests.swift`:

```swift
extension ModelTests {
    func test_transcript_persistsCuesLinkedToEpisode() throws {
        let ctx = try inMemoryContext()
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        let tr = Transcript(source: "published", language: "en")
        tr.episode = ep; ep.transcript = tr
        let cue = TranscriptCue(startTime: 0, endTime: 5, text: "Hello", speaker: nil)
        cue.transcript = tr; tr.cues.append(cue)
        [pod, ep, tr, cue].forEach { ctx.insert($0) }
        try ctx.save()

        let trs = try ctx.fetch(FetchDescriptor<Transcript>())
        XCTAssertEqual(trs.first?.cues.count, 1)
        XCTAssertEqual(trs.first?.episode?.guid, "g")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ModelTests/test_transcript_persistsCuesLinkedToEpisode`
Expected: FAIL — `cannot find 'Transcript' in scope`.

- [ ] **Step 3: Add the models + fields**

Create `Onda/Models/Transcript.swift`:

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

@Model
final class TranscriptCue {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var transcript: Transcript?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}
```

In `Onda/Models/ModelSchema.swift`, append `Transcript.self, TranscriptCue.self` to `ondaSchema`.

In `Onda/Models/Episode.swift`, add properties:
```swift
    var transcriptURL: URL?
    var transcriptType: String?

    @Relationship(deleteRule: .cascade, inverse: \Transcript.episode)
    var transcript: Transcript?
```
Add `transcriptURL: URL? = nil, transcriptType: String? = nil` to the initializer and assign them.

In `Onda/Networking/RSSFeedParser.swift`:
- Add `let transcriptURL: URL?` and `let transcriptType: String?` to `ParsedEpisode`.
- In `FeedDelegate`, add to the per-item struct `var transcriptURL: URL?` and `var transcriptType: String?`; in `didStartElement`, prefer JSON over VTT over SRT:
```swift
        case "podcast:transcript":
            if inItem, let u = attrs["url"] {
                let type = attrs["type"] ?? ""
                let rank: (String) -> Int = { t in t.contains("json") ? 3 : (t.contains("vtt") ? 2 : (t.contains("srt") ? 1 : 0)) }
                if current?.transcriptURL == nil || rank(type) > rank(current?.transcriptType ?? "") {
                    current?.transcriptURL = URL(string: u); current?.transcriptType = type
                }
            }
```
- In `buildFeed()`, pass `transcriptURL: it.transcriptURL, transcriptType: it.transcriptType` into each `ParsedEpisode`.

In `Onda/Services/SubscriptionService.swift` `refreshEpisodes`, when creating an `Episode` set:
```swift
            ep.transcriptURL = pe.transcriptURL
            ep.transcriptType = pe.transcriptType
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ModelTests`
Also re-run `RSSFeedParserTests` and `SubscriptionServiceTests` (updated initializers) — Expected: PASS.

> Note: adding `transcriptURL`/`transcriptType` to `ParsedEpisode` changes its initializer; update the `ParsedEpisode(...)` calls in `RSSFeedParserTests`, `SubscriptionServiceTests`, `FeedRefreshServiceTests`, and `PlaybackManagerTests` fixtures to pass `transcriptURL: nil, transcriptType: nil`.

- [ ] **Step 5: Commit**

```bash
git add Onda/Models OndaTests/ModelTests.swift Onda/Networking/RSSFeedParser.swift Onda/Services/SubscriptionService.swift OndaTests
git commit -m "feat: Transcript/TranscriptCue models + capture <podcast:transcript> from feeds"
```

---

### Task 2: TranscriptParser (VTT / SRT / PC2.0 JSON)

**Files:**
- Create: `Onda/Transcription/ParsedCue.swift`, `Onda/Transcription/TranscriptParser.swift`
- Create: `OndaTests/Fixtures/transcript.vtt`, `transcript.srt`, `transcript_pc20.json`, `OndaTests/TranscriptParserTests.swift`

**Interfaces:**
- Produces:
  - `struct ParsedCue: Equatable { let startTime: TimeInterval; let endTime: TimeInterval; let text: String; let speaker: String? }`
  - `struct TranscriptParser { func parse(_ data: Data, type: String) -> [ParsedCue] }` — dispatches on MIME/extension hint (`json`→PC2.0, `vtt`→WebVTT, `srt`→SubRip); on unknown, sniffs content.
  - `static func parseTimestamp(_ s: String) -> TimeInterval` (handles `00:01:02.500` and `00:01:02,500` and `01:02.500`).

- [ ] **Step 1: Add fixtures**

Create `OndaTests/Fixtures/transcript.vtt`:

```
WEBVTT

00:00:00.000 --> 00:00:03.000
<v Host>Welcome to the show.

00:00:03.000 --> 00:00:06.500
Today we talk about homepages.
```

Create `OndaTests/Fixtures/transcript.srt`:

```
1
00:00:00,000 --> 00:00:03,000
Welcome to the show.

2
00:00:03,000 --> 00:00:06,500
Today we talk about homepages.
```

Create `OndaTests/Fixtures/transcript_pc20.json`:

```json
{
  "version": "1.0.0",
  "segments": [
    { "startTime": 0.0, "endTime": 3.0, "speaker": "Host", "body": "Welcome to the show." },
    { "startTime": 3.0, "endTime": 6.5, "body": "Today we talk about homepages." }
  ]
}
```

- [ ] **Step 2: Write failing tests**

Create `OndaTests/TranscriptParserTests.swift`:

```swift
//  TranscriptParserTests.swift
import XCTest
@testable import Onda

final class TranscriptParserTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: ext)!)
    }

    func test_parseVTT_withSpeaker() throws {
        let cues = TranscriptParser().parse(try fixture("transcript", "vtt"), type: "text/vtt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].endTime, 3, accuracy: 0.001)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertEqual(cues[0].text, "Welcome to the show.")
        XCTAssertEqual(cues[1].startTime, 3, accuracy: 0.001)
    }

    func test_parseSRT() throws {
        let cues = TranscriptParser().parse(try fixture("transcript", "srt"), type: "application/x-subrip")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].endTime, 6.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Today we talk about homepages.")
    }

    func test_parsePC20JSON_withOptionalSpeaker() throws {
        let cues = TranscriptParser().parse(try fixture("transcript_pc20", "json"), type: "application/json")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].speaker, "Host")
        XCTAssertNil(cues[1].speaker)
    }

    func test_timestampFormats() {
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02.500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("00:01:02,500"), 62.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptParser.parseTimestamp("01:02.500"), 62.5, accuracy: 0.001)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptParserTests`
Expected: FAIL — `cannot find 'TranscriptParser' in scope`.

- [ ] **Step 4: Write the parser**

Create `Onda/Transcription/ParsedCue.swift`:

```swift
//  ParsedCue.swift
import Foundation

struct ParsedCue: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?
}
```

Create `Onda/Transcription/TranscriptParser.swift`:

```swift
//  TranscriptParser.swift
import Foundation

struct TranscriptParser {
    func parse(_ data: Data, type: String) -> [ParsedCue] {
        let hint = type.lowercased()
        let text = String(data: data, encoding: .utf8) ?? ""
        if hint.contains("json") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return parseJSON(data)
        }
        if hint.contains("srt") || hint.contains("subrip") { return parseCueBlocks(text, srt: true) }
        return parseCueBlocks(text, srt: false)   // default: WebVTT
    }

    static func parseTimestamp(_ s: String) -> TimeInterval {
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func parseJSON(_ data: Data) -> [ParsedCue] {
        struct Doc: Codable {
            struct Seg: Codable { let startTime: Double?; let endTime: Double?; let speaker: String?; let body: String? }
            let segments: [Seg]
        }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return [] }
        return doc.segments.compactMap { seg in
            guard let body = seg.body, !body.isEmpty else { return nil }
            return ParsedCue(startTime: seg.startTime ?? 0, endTime: seg.endTime ?? (seg.startTime ?? 0),
                             text: body, speaker: seg.speaker)
        }
    }

    private func parseCueBlocks(_ text: String, srt: Bool) -> [ParsedCue] {
        var cues: [ParsedCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }
            if lines[0].uppercased().hasPrefix("WEBVTT") { continue }
            if srt, Int(lines[0]) != nil { lines.removeFirst() }        // drop SRT index line
            guard let timing = lines.first(where: { $0.contains("-->") }) else { continue }
            let ends = timing.components(separatedBy: "-->")
            guard ends.count == 2 else { continue }
            let start = Self.parseTimestamp(ends[0])
            let end = Self.parseTimestamp(ends[1].components(separatedBy: " ").first ?? ends[1])
            let bodyLines = lines.drop { $0 != timing }.dropFirst()
            var body = bodyLines.joined(separator: " ")
            var speaker: String? = nil
            if let r = body.range(of: "^<v ([^>]+)>", options: .regularExpression) {
                speaker = String(body[r]).replacingOccurrences(of: "<v ", with: "").replacingOccurrences(of: ">", with: "")
                body.removeSubrange(r)
            }
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(ParsedCue(startTime: start, endTime: end, text: body, speaker: speaker))
        }
        return cues
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptParserTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Onda/Transcription/ParsedCue.swift Onda/Transcription/TranscriptParser.swift OndaTests/TranscriptParserTests.swift OndaTests/Fixtures/transcript.vtt OndaTests/Fixtures/transcript.srt OndaTests/Fixtures/transcript_pc20.json
git commit -m "feat: TranscriptParser (WebVTT/SRT/Podcasting-2.0 JSON → cues)"
```

---

### Task 3: ActiveCue (pure position→cue mapping)

**Files:**
- Create: `Onda/Transcription/ActiveCue.swift`, `OndaTests/ActiveCueTests.swift`

**Interfaces:**
- Produces: `enum ActiveCue { static func index(at seconds: TimeInterval, cues: [(start: TimeInterval, end: TimeInterval)]) -> Int? }` — index of the cue whose `[start, end)` contains `seconds`; if between cues, the most recent past cue; nil before the first.

- [ ] **Step 1: Write failing tests**

Create `OndaTests/ActiveCueTests.swift`:

```swift
//  ActiveCueTests.swift
import XCTest
@testable import Onda

final class ActiveCueTests: XCTestCase {
    private let cues: [(start: TimeInterval, end: TimeInterval)] = [(0, 3), (3, 6.5), (10, 12)]
    func test_insideCue() { XCTAssertEqual(ActiveCue.index(at: 4, cues: cues), 1) }
    func test_beforeFirst() { XCTAssertNil(ActiveCue.index(at: -1, cues: cues)) }
    func test_betweenCues_returnsMostRecentPast() { XCTAssertEqual(ActiveCue.index(at: 8, cues: cues), 1) }
    func test_afterLast() { XCTAssertEqual(ActiveCue.index(at: 100, cues: cues), 2) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ActiveCueTests`
Expected: FAIL — `cannot find 'ActiveCue' in scope`.

- [ ] **Step 3: Write ActiveCue**

Create `Onda/Transcription/ActiveCue.swift`:

```swift
//  ActiveCue.swift
import Foundation

enum ActiveCue {
    static func index(at seconds: TimeInterval, cues: [(start: TimeInterval, end: TimeInterval)]) -> Int? {
        guard let first = cues.first, seconds >= first.start else { return nil }
        var result: Int? = nil
        for (i, c) in cues.enumerated() where c.start <= seconds { result = i }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ActiveCueTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Transcription/ActiveCue.swift OndaTests/ActiveCueTests.swift
git commit -m "feat: ActiveCue position→cue mapping"
```

---

### Task 4: AudioTranscribing protocol + SpeechTranscriberEngine (iOS 26+)

**Files:**
- Create: `Onda/Transcription/AudioTranscribing.swift`

**Interfaces:**
- Produces:
  - `protocol AudioTranscribing { func transcribe(fileURL: URL, progress: @escaping (Double) -> Void) async throws -> [ParsedCue] }`
  - `@available(iOS 26, *) final class SpeechTranscriberEngine: AudioTranscribing` — uses `SpeechTranscriber`/`SpeechAnalyzer` on-device to produce time-aligned cues from a local file.
  - `enum TranscriptionError: Error { case unsupportedOS, notAuthorized, noAudioFile }`

> `SpeechTranscriber` yields results with `CMTimeRange`s; we map each result's range to a `ParsedCue` in feed-seconds. This is the only place that touches the Speech framework; everything else is OS-agnostic.

- [ ] **Step 1: Write the protocol + engine**

Create `Onda/Transcription/AudioTranscribing.swift`:

```swift
//  AudioTranscribing.swift
import Foundation

enum TranscriptionError: Error { case unsupportedOS, notAuthorized, noAudioFile }

protocol AudioTranscribing {
    func transcribe(fileURL: URL, progress: @escaping (Double) -> Void) async throws -> [ParsedCue]
}

#if canImport(Speech)
import Speech
import AVFoundation

@available(iOS 26, *)
final class SpeechTranscriberEngine: AudioTranscribing {
    func transcribe(fileURL: URL, progress: @escaping (Double) -> Void) async throws -> [ParsedCue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw TranscriptionError.noAudioFile }

        let transcriber = SpeechTranscriber(locale: .current,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let asset = AVURLAsset(url: fileURL)
        let total = (try? await asset.load(.duration).seconds) ?? 0
        var cues: [ParsedCue] = []

        let resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                let range = result.text.runs.first?.audioTimeRange
                let start = range?.start.seconds ?? 0
                let end = range?.end.seconds ?? start
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    cues.append(ParsedCue(startTime: start, endTime: end, text: text, speaker: nil))
                    if total > 0 { progress(min(1, end / total)) }
                }
            }
        }

        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            try await analyzer.analyzeSequence(from: audioFile)
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await resultsTask.value
        return cues
    }
}
#endif
```

> The exact `SpeechTranscriber`/`SpeechAnalyzer` result-shape may need adjustment against the installed iOS 26 SDK (the API stabilized post my knowledge cutoff). The seam that matters — `AudioTranscribing.transcribe(fileURL:progress:) -> [ParsedCue]` — is fixed; only the body of this one file changes if the SDK differs. Verify against Xcode's Speech headers when implementing.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`. (If the iOS 26 Speech result API differs, fix this file's body until it builds; do not change the protocol.)

- [ ] **Step 3: Commit**

```bash
git add Onda/Transcription/AudioTranscribing.swift
git commit -m "feat: AudioTranscribing protocol + iOS 26 SpeechTranscriberEngine"
```

---

### Task 5: TranscriptService (choose source, persist, authorize)

**Files:**
- Create: `Onda/Transcription/TranscriptService.swift`
- Create: `OndaTests/TranscriptServiceTests.swift`
- Modify: `project.yml` (add `NSSpeechRecognitionUsageDescription`)

**Interfaces:**
- Consumes: `TranscriptParser`, `AudioTranscribing`, `PlaybackManager.localURL(for:)` (Plan 3), `ModelContext`.
- Produces:
  - `@Observable final class TranscriptService`
  - `init(modelContext: ModelContext, parser: TranscriptParser = .init(), engine: AudioTranscribing?, fetch: @escaping (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }, localURL: @escaping (Episode) -> URL?)`
  - `var progress: [String: Double]` (guid → 0…1 for on-device runs)
  - `func transcript(for episode: Episode) async -> Transcript?` — returns the cached `Transcript` if present; else if `transcriptURL` set → fetch+parse+persist (`source:"published"`); else if `engine != nil` and downloaded → transcribe+persist (`source:"ondevice"`); else nil.
  - `func canTranscribeOnDevice(_ episode: Episode) -> Bool` (engine present + downloaded)
  - `static func requestSpeechAuthorization() async -> Bool`
  - `func persist(cues:for:source:) -> Transcript` (pure-ish DB write; tested directly)

- [ ] **Step 1: Write failing tests (published fetch + on-device via stub)**

Create `OndaTests/TranscriptServiceTests.swift`:

```swift
//  TranscriptServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubEngine: AudioTranscribing {
    var cues: [ParsedCue]
    func transcribe(fileURL: URL, progress: @escaping (Double) -> Void) async throws -> [ParsedCue] {
        progress(1.0); return cues
    }
}

final class TranscriptServiceTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }
    private func episode(in ctx: ModelContext, transcriptURL: URL? = nil) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "",
                         transcriptURL: transcriptURL, transcriptType: transcriptURL == nil ? nil : "text/vtt")
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_publishedTranscript_fetchedParsedAndPersisted() async throws {
        let ctx = try ctx()
        let ep = episode(in: ctx, transcriptURL: URL(string: "https://ex.com/t.vtt"))
        let vtt = Data("WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nHello there.".utf8)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in vtt }, localURL: { _ in nil })
        let tr = await svc.transcript(for: ep)
        XCTAssertEqual(tr?.source, "published")
        XCTAssertEqual(tr?.cues.count, 1)
        XCTAssertEqual(tr?.cues.first?.text, "Hello there.")
        // Cached: second call returns the same persisted transcript without refetching.
        let again = await svc.transcript(for: ep)
        XCTAssertEqual(again?.cues.count, 1)
    }

    func test_noPublished_butEngineAndDownloaded_usesOnDevice() async throws {
        let ctx = try ctx()
        let ep = episode(in: ctx, transcriptURL: nil)
        let stub = StubEngine(cues: [ParsedCue(startTime: 0, endTime: 2, text: "On device", speaker: nil)])
        let svc = TranscriptService(modelContext: ctx, engine: stub,
                                    fetch: { _ in Data() },
                                    localURL: { _ in URL(fileURLWithPath: "/tmp/e.mp3") })
        let tr = await svc.transcript(for: ep)
        XCTAssertEqual(tr?.source, "ondevice")
        XCTAssertEqual(tr?.cues.first?.text, "On device")
    }

    func test_noPublished_noEngine_returnsNil() async throws {
        let ctx = try ctx()
        let ep = episode(in: ctx, transcriptURL: nil)
        let svc = TranscriptService(modelContext: ctx, engine: nil,
                                    fetch: { _ in Data() }, localURL: { _ in nil })
        let tr = await svc.transcript(for: ep)
        XCTAssertNil(tr)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptServiceTests`
Expected: FAIL — `cannot find 'TranscriptService' in scope`.

- [ ] **Step 3: Write TranscriptService + Info key**

Create `Onda/Transcription/TranscriptService.swift`:

```swift
//  TranscriptService.swift
import Foundation
import SwiftData
#if canImport(Speech)
import Speech
#endif

@Observable
final class TranscriptService {
    typealias Fetch = (URL) async throws -> Data
    private let modelContext: ModelContext
    private let parser: TranscriptParser
    private let engine: AudioTranscribing?
    private let fetch: Fetch
    private let localURL: (Episode) -> URL?

    var progress: [String: Double] = [:]

    init(modelContext: ModelContext, parser: TranscriptParser = .init(),
         engine: AudioTranscribing?, fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         localURL: @escaping (Episode) -> URL?) {
        self.modelContext = modelContext
        self.parser = parser
        self.engine = engine
        self.fetch = fetch
        self.localURL = localURL
    }

    func canTranscribeOnDevice(_ episode: Episode) -> Bool { engine != nil && localURL(episode) != nil }

    func transcript(for episode: Episode) async -> Transcript? {
        if let existing = episode.transcript, !existing.cues.isEmpty { return existing }

        if let url = episode.transcriptURL {
            do {
                let data = try await fetch(url)
                let cues = parser.parse(data, type: episode.transcriptType ?? "")
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "published") }
            } catch { /* fall through */ }
        }

        if let engine, let file = localURL(episode) {
            do {
                let cues = try await engine.transcribe(fileURL: file) { [weak self] p in
                    self?.progress[episode.guid] = p
                }
                progress[episode.guid] = nil
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "ondevice") }
            } catch { progress[episode.guid] = nil }
        }
        return nil
    }

    @discardableResult
    func persist(cues: [ParsedCue], for episode: Episode, source: String) -> Transcript {
        let tr = Transcript(source: source, language: Locale.current.language.languageCode?.identifier ?? "en")
        tr.episode = episode
        episode.transcript = tr
        modelContext.insert(tr)
        for pc in cues {
            let cue = TranscriptCue(startTime: pc.startTime, endTime: pc.endTime, text: pc.text, speaker: pc.speaker)
            cue.transcript = tr; tr.cues.append(cue)
            modelContext.insert(cue)
        }
        try? modelContext.save()
        return tr
    }

    static func requestSpeechAuthorization() async -> Bool {
        #if canImport(Speech)
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
        #else
        return false
        #endif
    }
}
```

In `project.yml` under the `Onda` target `settings.base`, add:
```yaml
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Onda transcribes downloaded episodes on your device so you can read and search them."
```
Then `xcodegen generate`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptServiceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Transcription/TranscriptService.swift OndaTests/TranscriptServiceTests.swift project.yml
git commit -m "feat: TranscriptService (published-first, on-device fallback, on-demand + cached)"
```

---

### Task 6: TranscriptSearch

**Files:**
- Create: `Onda/Transcription/TranscriptSearch.swift`, `OndaTests/TranscriptSearchTests.swift`

**Interfaces:**
- Produces:
  - `struct TranscriptHit { let episodeGuid: String; let episodeTitle: String; let showTitle: String; let cueText: String; let startTime: TimeInterval }`
  - `struct TranscriptSearch { init(modelContext: ModelContext); func search(_ query: String) -> [TranscriptHit] }` — case-insensitive `contains` over `TranscriptCue.text`, limited to cues whose transcript's episode's podcast is subscribed; sorted by show then time.

- [ ] **Step 1: Write failing test**

Create `OndaTests/TranscriptSearchTests.swift`:

```swift
//  TranscriptSearchTests.swift
import XCTest
import SwiftData
@testable import Onda

final class TranscriptSearchTests: XCTestCase {
    func test_search_findsMatchingCues_inSubscribedShows() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        let c1 = TranscriptCue(startTime: 10, endTime: 12, text: "the slow death of the homepage", speaker: nil)
        let c2 = TranscriptCue(startTime: 40, endTime: 42, text: "octopus cognition is wild", speaker: nil)
        [c1, c2].forEach { $0.transcript = tr; tr.cues.append($0) }
        [pod, ep, tr, c1, c2].forEach { ctx.insert($0) }
        try ctx.save()

        let hits = TranscriptSearch(modelContext: ctx).search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertEqual(hits.first?.showTitle, "The Signal")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptSearchTests`
Expected: FAIL — `cannot find 'TranscriptSearch' in scope`.

- [ ] **Step 3: Write TranscriptSearch**

Create `Onda/Transcription/TranscriptSearch.swift`:

```swift
//  TranscriptSearch.swift
import Foundation
import SwiftData

struct TranscriptHit: Identifiable {
    var id: String { episodeGuid + "-\(startTime)" }
    let episodeGuid: String
    let episodeTitle: String
    let showTitle: String
    let cueText: String
    let startTime: TimeInterval
}

struct TranscriptSearch {
    private let modelContext: ModelContext
    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func search(_ query: String) -> [TranscriptHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let descriptor = FetchDescriptor<TranscriptCue>(
            predicate: #Predicate { $0.text.localizedStandardContains(q) })
        let cues = (try? modelContext.fetch(descriptor)) ?? []
        let hits = cues.compactMap { cue -> TranscriptHit? in
            guard let ep = cue.transcript?.episode, let pod = ep.podcast, pod.isSubscribed else { return nil }
            return TranscriptHit(episodeGuid: ep.guid, episodeTitle: ep.title,
                                 showTitle: pod.title, cueText: cue.text, startTime: cue.startTime)
        }
        return hits.sorted { ($0.showTitle, $0.startTime) < ($1.showTitle, $1.startTime) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/TranscriptSearchTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Onda/Transcription/TranscriptSearch.swift OndaTests/TranscriptSearchTests.swift
git commit -m "feat: TranscriptSearch full-text over cues in subscribed shows"
```

---

### Task 7: Transcript view (follow-along + captions) in Now Playing

**Files:**
- Create: `Onda/Player/TranscriptView.swift`
- Modify: `Onda/Player/NowPlayingView.swift`, `Onda/OndaApp.swift`

**Interfaces:**
- Consumes: `TranscriptService`, `PlaybackManager`, `ActiveCue`.
- Produces:
  - `TranscriptView(episode:)` — loads via `TranscriptService.transcript(for:)`; renders cues in a `ScrollViewReader`; the active cue (from `ActiveCue.index(at: playback.positionSeconds …)`) is highlighted and auto-scrolled; tap a cue → `playback.seek(toFraction: cue.startTime / duration)`. When no transcript and `canTranscribeOnDevice`, shows a "Transcribe episode" button with progress; otherwise "No transcript available."
  - `NowPlayingView` gains a transcript (quote/text) button opening `TranscriptView` as a sheet.
  - App injects `TranscriptService`.

- [ ] **Step 1: Write the transcript view**

Create `Onda/Player/TranscriptView.swift`:

```swift
//  TranscriptView.swift
import SwiftUI

struct TranscriptView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(TranscriptService.self) private var transcripts
    let episode: Episode

    @State private var transcript: Transcript?
    @State private var loading = false
    @State private var transcribing = false

    private var cues: [TranscriptCue] {
        (transcript?.cues ?? []).sorted { $0.startTime < $1.startTime }
    }
    private var activeIndex: Int? {
        ActiveCue.index(at: playback.positionSeconds, cues: cues.map { ($0.startTime, $0.endTime) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let t = transcript, !t.cues.isEmpty { transcriptList }
                else if loading || transcribing { progressState }
                else { emptyState }
            }
            .background(theme.color(.bg))
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { i, cue in
                        Button {
                            playback.seek(toFraction: cue.startTime / max(1, episode.duration))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let s = cue.speaker {
                                    Text(s).font(.system(size: 12, weight: .bold)).textCase(.uppercase)
                                        .foregroundStyle(theme.color(.accent))
                                }
                                Text(cue.text).font(.system(size: 16))
                                    .foregroundStyle(i == activeIndex ? theme.color(.text) : theme.color(.textTertiary))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(i == activeIndex ? theme.color(.accentWash) : .clear)
                        }
                        .buttonStyle(.plain).id(i)
                    }
                }.padding(20)
            }
            .onChange(of: activeIndex) { _, new in
                if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView(value: transcripts.progress[episode.guid] ?? 0)
                .tint(theme.color(.accent)).frame(maxWidth: 220)
            Text(transcribing ? "Transcribing on device…" : "Loading transcript…")
                .foregroundStyle(theme.color(.textTertiary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No transcript available").foregroundStyle(theme.color(.textTertiary))
            if transcripts.canTranscribeOnDevice(episode) {
                Button("Transcribe episode") { Task { await transcribe() } }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            } else {
                Text("Available for downloaded episodes on iOS 26+")
                    .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard transcript == nil else { return }
        // Only auto-load if published (cheap); on-device requires explicit tap.
        if episode.transcript != nil || episode.transcriptURL != nil {
            loading = true
            transcript = await transcripts.transcript(for: episode)
            loading = false
        }
    }

    private func transcribe() async {
        guard await TranscriptService.requestSpeechAuthorization() else { return }
        transcribing = true
        transcript = await transcripts.transcript(for: episode)
        transcribing = false
    }
}
```

- [ ] **Step 2: Add the transcript button to Now Playing + inject the service**

In `Onda/Player/NowPlayingView.swift` header (or near the queue button), add `@State private var showTranscript = false`, a button `Button { showTranscript = true } label: { Image(systemName: "text.quote") }`, and `.sheet(isPresented: $showTranscript) { if let ep { TranscriptView(episode: ep) } }`.

In `Onda/OndaApp.swift`, add and inject:
```swift
    @State private var transcripts: TranscriptService
```
in `init` after `playback` is created:
```swift
            let pm = PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext)
            _playback = State(initialValue: pm)
            let engine: AudioTranscribing? = {
                if #available(iOS 26, *) { return SpeechTranscriberEngine() } else { return nil }
            }()
            _transcripts = State(initialValue: TranscriptService(
                modelContext: c.mainContext, engine: engine,
                localURL: { pm.localURL(for: $0) }))
```
(adjust so `pm` is the same instance used for `_playback`) and add `.environment(transcripts)` in `body`.

- [ ] **Step 3: Build and run — verify a published-transcript show follows playback**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Launch, play an episode from a show that publishes a `<podcast:transcript>` (many do), open the transcript button → cues render, the active cue highlights and auto-scrolls as audio plays, tapping a cue seeks.

- [ ] **Step 4: Commit**

```bash
git add Onda/Player/TranscriptView.swift Onda/Player/NowPlayingView.swift Onda/OndaApp.swift
git commit -m "feat: follow-along Transcript view (captions) in Now Playing"
```

---

### Task 8: Library transcript search

**Files:**
- Create: `Onda/Library/LibrarySearchView.swift`
- Modify: `Onda/Shell/LibraryView.swift`, `Onda/OndaApp.swift`

**Interfaces:**
- Consumes: `TranscriptSearch`, `PlaybackManager`.
- Produces:
  - `LibrarySearchView` — a search field; results are `TranscriptHit` rows (show, episode, snippet, timestamp); tapping a hit finds the `Episode`, plays it, and seeks to `hit.startTime`.
  - `LibraryView` gains a search icon in its header opening `LibrarySearchView`.

- [ ] **Step 1: Write the search screen**

Create `Onda/Library/LibrarySearchView.swift`:

```swift
//  LibrarySearchView.swift
import SwiftUI
import SwiftData

struct LibrarySearchView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Query private var episodes: [Episode]

    @State private var query = ""
    @State private var hits: [TranscriptHit] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
                    TextField("Search transcripts", text: $query)
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
                .padding(20)

                List(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.showTitle).brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                            Text(hit.cueText).font(.system(size: 15)).foregroundStyle(theme.color(.text))
                                .lineLimit(2)
                            Text(hit.episodeTitle + " · " + timeStr(hit.startTime))
                                .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                }
            }
            .background(theme.color(.bg))
            .navigationTitle("Search")
            .onChange(of: query) { _, q in
                hits = TranscriptSearch(modelContext: modelContext).search(q)
            }
        }
    }

    private func open(_ hit: TranscriptHit) {
        guard let ep = episodes.first(where: { $0.guid == hit.episodeGuid }) else { return }
        playback.play(ep)
        playback.seek(toFraction: hit.startTime / max(1, ep.duration))
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 2: Add the search entry point to Library**

In `Onda/Shell/LibraryView.swift`, add `@State private var showSearch = false`, a search button beside the "Library" title (`Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }`), and `.sheet(isPresented: $showSearch) { LibrarySearchView() }`.

- [ ] **Step 3: Build and run — verify transcript search jumps to the moment**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Launch: with at least one episode transcribed/opened (so cues are persisted), open Library search, type a word you heard → hits list; tap → the episode plays from that moment.

- [ ] **Step 4: Commit**

```bash
git add Onda/Library/LibrarySearchView.swift Onda/Shell/LibraryView.swift
git commit -m "feat: Library transcript search with jump-to-moment"
```

---

### Task 9: Full regression pass

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: all suites from Plans 1–5 **plus** `TranscriptParserTests`, `ActiveCueTests`, `TranscriptServiceTests`, `TranscriptSearchTests`, and the new `ModelTests` case PASS.

- [ ] **Step 2: Manual smoke test of transcription end-to-end**

Play a published-transcript show → follow-along highlights + auto-scroll + tap-to-seek; on iOS 26 device/sim, download a no-transcript episode → "Transcribe episode" → progress → transcript appears; Library search finds a spoken phrase and jumps to it.

- [ ] **Step 3: Commit fixes**

```bash
git commit -am "fix: transcription regression fixes from smoke test" || true
```

---

## Self-Review

- **Spec coverage:** published-transcript-first via `<podcast:transcript>` parse ✓; on-device Apple Speech fallback gated iOS 26+, opt-in, downloaded-only ✓; follow-along transcript view doubling as captions/accessibility ✓; full-text transcript search across subscriptions with jump-to-moment ✓; on-demand fetch + SwiftData caching ✓; Speech authorization + Info key ✓; ad/chapter inference explicitly excluded ✓; cue times in feed-seconds reusing canonical timeline ✓.
- **Placeholder scan:** The one SDK-dependent body (`SpeechTranscriberEngine.transcribe`) is flagged as verify-against-iOS-26-headers with a fixed protocol seam — not a placeholder (it has a real, compilable implementation to adjust). All other steps are complete code.
- **Type consistency:** `ParsedCue`, `TranscriptParser.parse(_:type:)`, `AudioTranscribing.transcribe(fileURL:progress:)`, `TranscriptService(modelContext:parser:engine:fetch:localURL:)` / `transcript(for:)` / `canTranscribeOnDevice(_:)` / `progress`, `ActiveCue.index(at:cues:)`, `TranscriptSearch(modelContext:).search(_:)` / `TranscriptHit`, and the `Transcript`/`TranscriptCue` model inits are used identically across tasks. Consumes `PlaybackManager.localURL(for:)`, `seek(toFraction:)`, `positionSeconds`, `play(_:)` exactly as defined in Plan 3.
