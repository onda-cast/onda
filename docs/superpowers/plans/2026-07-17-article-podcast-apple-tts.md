# Article-to-Podcast (Apple TTS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a pasted or shared web-article URL into a playable, transcript-synced episode narrated by `AVSpeechSynthesizer`, living in a synthetic "Articles" show.

**Architecture:** New `Onda/Article/` feature directory: `ArticleExtractor` (URLSession fetch + Readability.js in an off-screen WKWebView) → `SentenceSplitter` (NLTokenizer) → `ArticleSpeechRenderer` (`AVSpeechSynthesizer.write` → one `.m4a` + per-sentence `ParsedCue`s) → `ArticleConversionService` (orchestration + batch SwiftData insert). Rendered audio lands in the existing `Application Support/Downloads/` directory with a real `DownloadedFile` row, so playback/retention/storage UI need zero changes. A Share Extension writes shared URLs to an App Group JSON queue that the main app drains on foreground.

**Tech Stack:** SwiftUI, SwiftData, WebKit (WKWebView), NaturalLanguage (NLTokenizer), AVFoundation (AVSpeechSynthesizer, AVAudioFile), Mozilla Readability.js (vendored), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-17-article-podcast-apple-tts-design.md`

## Global Constraints

- Swift 6 (`SWIFT_VERSION: "6.0"`), deployment target iOS 17.0.
- SwiftLint: max line length 150 (warning); config `.swiftlint.yml`.
- `Onda.xcodeproj` is generated — after adding/removing files or editing `project.yml`, run `xcodegen generate` before building.
- Build: `xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
- Test one class: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/<ClassName>`
- Canonical timeline: all cue times are seconds in the rendered audio file (these episodes have no trim/skip effects at render time, so file seconds ARE feed seconds).
- App Group ID is `group.com.chasegilliam.onda` (deviation from spec's placeholder `group.com.onda.shared` — matches the project's `com.chasegilliam` bundle prefix; automatic signing registers it).
- Views are not unit-tested in this codebase; UI tasks end with a clean build + SwiftLint instead.
- SwiftData relationship arrays must be assigned in bulk, never appended in a loop (quadratic — see `TranscriptService.persist`).

---

### Task 1: Model & schema changes

**Files:**
- Create: `Onda/Models/ArticleSource.swift`
- Modify: `Onda/Models/Podcast.swift` (add `isLocal`)
- Modify: `Onda/Models/Episode.swift` (add `sourceType`, `articleSource` relationship)
- Modify: `Onda/Models/ShowSettings.swift` (add `ttsVoiceIdentifier`)
- Modify: `Onda/Models/ModelSchema.swift` (register `ArticleSource`)
- Test: `OndaTests/ArticleModelTests.swift`

**Interfaces:**
- Consumes: existing `Podcast`, `Episode`, `ShowSettings` models.
- Produces: `Podcast.isLocal: Bool` (default `false`), `Episode.sourceType: String` (default `"feed"`), `Episode.articleSource: ArticleSource?` (cascade), `ArticleSource(sourceURL: URL, siteName: String?, addedAt: Date)` with `episode: Episode?` back-ref, `ShowSettings.ttsVoiceIdentifier: String?` (default `nil`). All later tasks rely on these exact names.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ArticleModelTests.swift`:

```swift
//  ArticleModelTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ArticleModelTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_defaults_feedSourcedModels() throws {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        XCTAssertFalse(pod.isLocal)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        XCTAssertEqual(ep.sourceType, "feed")
        XCTAssertNil(ep.articleSource)
        XCTAssertNil(ShowSettings.makeDefault().ttsVoiceIdentifier)
    }

    func test_articleSource_persistsAndCascadesWithEpisode() throws {
        let ctx = try makeContext()
        let ep = Episode(guid: "article-1", title: "T", publishDate: .now, duration: 10,
                         audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), notes: "")
        ep.sourceType = "article"
        ctx.insert(ep)
        let src = ArticleSource(sourceURL: URL(string: "https://ex.com/story")!,
                                siteName: "Example", addedAt: .now)
        src.episode = ep
        ep.articleSource = src
        ctx.insert(src)
        try ctx.save()

        XCTAssertEqual(ep.articleSource?.siteName, "Example")
        ctx.delete(ep)
        try ctx.save()
        let remaining = try ctx.fetch(FetchDescriptor<ArticleSource>())
        XCTAssertTrue(remaining.isEmpty, "ArticleSource must cascade-delete with its Episode")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleModelTests`
Expected: BUILD FAILURE — `cannot find 'ArticleSource' in scope`, `no member 'isLocal'`, etc.

- [ ] **Step 3: Implement the model changes**

Create `Onda/Models/ArticleSource.swift`:

```swift
//  ArticleSource.swift
import Foundation
import SwiftData

/// Where a TTS-converted article episode came from. 1:1 with Episode, same shape
/// as DownloadedFile/Transcript.
@Model
final class ArticleSource {
    var sourceURL: URL
    var siteName: String?
    var addedAt: Date
    var episode: Episode?

    init(sourceURL: URL, siteName: String?, addedAt: Date) {
        self.sourceURL = sourceURL
        self.siteName = siteName
        self.addedAt = addedAt
    }
}
```

In `Onda/Models/Podcast.swift`, after `var isSubscribed: Bool` (line 13) add:

```swift
    var isLocal: Bool = false   // synthetic show (e.g. "Articles") — no feed to refresh
```

In `Onda/Models/Episode.swift`, after `var isArchived: Bool = false` (line 16) add:

```swift
    var sourceType: String = "feed"   // "feed" | "article" — mirrors Chapter.source tagging
```

and after the `transcript` relationship (line 30) add:

```swift
    @Relationship(deleteRule: .cascade, inverse: \ArticleSource.episode)
    var articleSource: ArticleSource?
```

In `Onda/Models/ShowSettings.swift`, after `var keepTranscriptsOverride: Bool?` (line 19) add:

```swift
    var ttsVoiceIdentifier: String?   // Articles show only; nil = system default voice
```

In `Onda/Models/ModelSchema.swift` append `ArticleSource.self` to the array:

```swift
let ondaSchema: [any PersistentModel.Type] = [
    Podcast.self, Episode.self, Chapter.self,
    ShowSettings.self, QueueItem.self, DownloadedFile.self,
    Transcript.self, TranscriptCue.self, Clip.self, ArticleSource.self
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleModelTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Onda/Models/ OndaTests/ArticleModelTests.swift
git commit -m "feat: model groundwork for article episodes (ArticleSource, isLocal, sourceType, ttsVoiceIdentifier)"
```

---

### Task 2: SentenceSplitter

**Files:**
- Create: `Onda/Article/SentenceSplitter.swift`
- Test: `OndaTests/SentenceSplitterTests.swift`

**Interfaces:**
- Produces: `SentenceSplitter.split(_ text: String) -> [String]` — trimmed, non-empty sentences in order. Task 5 calls this.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/SentenceSplitterTests.swift`:

```swift
//  SentenceSplitterTests.swift
import XCTest
@testable import Onda

final class SentenceSplitterTests: XCTestCase {
    func test_splitsProseIntoSentences() {
        let text = "The tern flew south. It crossed two oceans! Where would it land next? Nobody knew."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["The tern flew south.", "It crossed two oceans!",
                        "Where would it land next?", "Nobody knew."])
    }

    func test_handlesAbbreviationsAndNewlines() {
        let text = "Dr. Smith arrived at 5 p.m. on Tuesday.\n\nShe left early."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["Dr. Smith arrived at 5 p.m. on Tuesday.", "She left early."])
    }

    func test_emptyAndWhitespaceOnly_returnEmpty() {
        XCTAssertEqual(SentenceSplitter.split(""), [])
        XCTAssertEqual(SentenceSplitter.split("  \n\t "), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SentenceSplitterTests`
Expected: BUILD FAILURE — `cannot find 'SentenceSplitter' in scope`

- [ ] **Step 3: Implement**

Create `Onda/Article/SentenceSplitter.swift`:

```swift
//  SentenceSplitter.swift
import Foundation
import NaturalLanguage

/// Splits article prose into sentences for per-utterance TTS rendering.
/// NLTokenizer handles abbreviations/locales far better than punctuation regexes.
enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SentenceSplitterTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/SentenceSplitter.swift OndaTests/SentenceSplitterTests.swift
git commit -m "feat: sentence splitter for article TTS rendering"
```

---

### Task 3: Vendor Readability.js + ArticleExtractor

**Files:**
- Create: `Resources/Readability.js` (vendored, ~90 KB)
- Create: `Onda/Article/ArticleExtractor.swift`
- Create: `OndaTests/Fixtures/article_basic.html`
- Modify: `project.yml` (bundle `Resources/` as resources)
- Test: `OndaTests/ArticleExtractorTests.swift`

**Interfaces:**
- Produces:
  - `struct ExtractedArticle: Equatable, Sendable { var title: String; var byline: String?; var siteName: String?; var textContent: String }`
  - `enum ArticleExtractionError: LocalizedError, Equatable { case invalidURL, fetchFailed, noReadableContent, timeout }`
  - `@MainActor final class ArticleExtractor` with `init(fetch: @escaping @Sendable (URL) async throws -> Data = ..., timeout: Duration = .seconds(20))` and `func extract(from url: URL) async throws -> ExtractedArticle`
- Task 5 consumes `extract(from:)` via a closure; Task 6 constructs the real extractor.

- [ ] **Step 1: Vendor Readability.js**

```bash
mkdir -p Resources
curl -fsSL -o Resources/Readability.js https://raw.githubusercontent.com/mozilla/readability/0.5.0/Readability.js
head -5 Resources/Readability.js
```

Expected: file starts with Mozilla's `/*eslint-env es6:false*/` / Apache-2.0 header comment. (Keep the header — it carries the license attribution.)

- [ ] **Step 2: Bundle it via project.yml**

In `project.yml`, change the Onda target's `sources:` from `sources: [Onda]` to:

```yaml
    sources:
      - Onda
      - path: Resources
        buildPhase: resources
```

Run: `xcodegen generate`
Expected: exits 0.

- [ ] **Step 3: Create the HTML fixture**

Create `OndaTests/Fixtures/article_basic.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>The Long Migration</title>
</head>
<body>
  <nav>
    <a href="/">Home</a> <a href="/subscribe">SUBSCRIBE NOW</a> <a href="/login">Log in</a>
  </nav>
  <aside>Trending: ten gadgets you must buy before Friday. SUBSCRIBE NOW for unlimited access.</aside>
  <article>
    <h1>The Long Migration</h1>
    <p class="byline">By Jordan Reyes</p>
    <p>Arctic terns make the longest migration of any animal on Earth, travelling from their
    Arctic breeding grounds to the Antarctic and back again every single year. Researchers who
    fitted the birds with tiny geolocators found round trips exceeding seventy thousand
    kilometres, a distance that comfortably eclipses earlier estimates and rewrites what
    biologists thought a four-ounce seabird could endure.</p>
    <p>The birds do not fly in straight lines. Instead they trace enormous looping detours that
    follow prevailing wind systems over the Atlantic and Indian Oceans, trading distance for
    energy savings the way sailors once traded time for the trade winds. A tern that hugged the
    great-circle route would fight headwinds for weeks; the loop costs kilometres but spares
    the wing muscles that must last three decades of annual journeys.</p>
    <p>What guides them remains only partly understood. Magnetic sensing, star patterns, polarized
    light and even smell have all been implicated in experiments, yet no single mechanism
    explains how a first-year bird with no map and no guide finds a specific stretch of
    Antarctic pack ice ten thousand kilometres from the nest where it hatched.</p>
    <p>For the researchers, the harder question is what climate change does to a species whose
    life is stretched between the two fastest-warming regions on the planet. Earlier ice
    breakup shifts the krill blooms the terns depend on, and the long-term data sets needed to
    detect a decline are only now reaching maturity.</p>
  </article>
  <footer>© Example Media. All rights reserved.</footer>
</body>
</html>
```

- [ ] **Step 4: Write the failing test**

Create `OndaTests/ArticleExtractorTests.swift`:

```swift
//  ArticleExtractorTests.swift
import XCTest
@testable import Onda

@MainActor
final class ArticleExtractorTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "html")!
        return try! Data(contentsOf: url)
    }

    func test_extractsArticleFromFixture_strippingChrome() async throws {
        let html = fixture("article_basic")
        let extractor = ArticleExtractor(fetch: { _ in html })
        let article = try await extractor.extract(from: URL(string: "https://example.com/terns")!)
        XCTAssertEqual(article.title, "The Long Migration")
        XCTAssertTrue(article.textContent.contains("Arctic terns"))
        XCTAssertTrue(article.textContent.contains("krill blooms"))
        XCTAssertFalse(article.textContent.contains("SUBSCRIBE NOW"), "nav/aside chrome must be stripped")
    }

    func test_pageWithNoArticle_throwsNoReadableContent() async {
        let html = Data("<html><body><nav><a href='/'>Home</a></nav></body></html>".utf8)
        let extractor = ArticleExtractor(fetch: { _ in html })
        do {
            _ = try await extractor.extract(from: URL(string: "https://example.com/empty")!)
            XCTFail("expected noReadableContent")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .noReadableContent)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_nonHTTPScheme_throwsInvalidURL() async {
        let extractor = ArticleExtractor(fetch: { _ in Data() })
        do {
            _ = try await extractor.extract(from: URL(string: "ftp://example.com/x")!)
            XCTFail("expected invalidURL")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .invalidURL)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_fetchError_throwsFetchFailed() async {
        struct Boom: Error {}
        let extractor = ArticleExtractor(fetch: { _ in throw Boom() })
        do {
            _ = try await extractor.extract(from: URL(string: "https://example.com/x")!)
            XCTFail("expected fetchFailed")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .fetchFailed)
        } catch { XCTFail("unexpected error \(error)") }
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleExtractorTests`
Expected: BUILD FAILURE — `cannot find 'ArticleExtractor' in scope`

- [ ] **Step 6: Implement ArticleExtractor**

Create `Onda/Article/ArticleExtractor.swift`:

```swift
//  ArticleExtractor.swift
import Foundation
import WebKit

enum ArticleExtractionError: LocalizedError, Equatable {
    case invalidURL, fetchFailed, noReadableContent, timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That link isn't a valid web address."
        case .fetchFailed: return "Couldn't load the page. Check the link and your connection."
        case .noReadableContent: return "No readable article found on that page."
        case .timeout: return "The page took too long to process."
        }
    }
}

struct ExtractedArticle: Equatable, Sendable {
    var title: String
    var byline: String?
    var siteName: String?
    var textContent: String
}

/// Fetches a URL's HTML and runs Mozilla's Readability.js (Safari-Reader-style extraction)
/// in an off-screen WKWebView. MainActor because WKWebView requires it.
@MainActor
final class ArticleExtractor: NSObject {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private let timeout: Duration
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?   // retained for the duration of one extract() call

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         timeout: Duration = .seconds(20)) {
        self.fetch = fetch
        self.timeout = timeout
    }

    func extract(from url: URL) async throws -> ExtractedArticle {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ArticleExtractionError.invalidURL
        }
        let data: Data
        do { data = try await fetch(url) } catch { throw ArticleExtractionError.fetchFailed }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ArticleExtractionError.noReadableContent
        }
        return try await withTimeout { try await self.runReadability(html: html, baseURL: url) }
    }

    private func runReadability(html: String, baseURL: URL) async throws -> ExtractedArticle {
        let web = WKWebView(frame: .zero)
        webView = web
        web.navigationDelegate = self
        defer { webView = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            web.loadHTMLString(html, baseURL: baseURL)
        }
        guard let jsURL = Bundle(for: ArticleExtractor.self).url(forResource: "Readability",
                                                                 withExtension: "js"),
              let readability = try? String(contentsOf: jsURL, encoding: .utf8) else {
            assertionFailure("Readability.js missing from bundle — check project.yml resources")
            throw ArticleExtractionError.noReadableContent
        }
        _ = try? await web.evaluateJavaScript(readability)
        let call = "JSON.stringify(new Readability(document).parse())"
        guard let raw = try? await web.evaluateJavaScript(call) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let dict = obj as? [String: Any],
              let text = (dict["textContent"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ArticleExtractionError.noReadableContent
        }
        return ExtractedArticle(
            title: (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? baseURL.host() ?? "Article",
            byline: dict["byline"] as? String,
            siteName: dict["siteName"] as? String,
            textContent: text)
    }

    private func withTimeout<T: Sendable>(
        _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await op() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw ArticleExtractionError.timeout
            }
            guard let result = try await group.next() else { throw ArticleExtractionError.timeout }
            group.cancelAll()
            return result
        }
    }
}

extension ArticleExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: ArticleExtractionError.fetchFailed)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        loadContinuation?.resume(throwing: ArticleExtractionError.fetchFailed)
        loadContinuation = nil
    }
}
```

Note: `Readability(document).parse()` returns `null` for unreadable pages → `JSON.stringify` yields the string `"null"` → `JSONSerialization` gives `NSNull`, the `as? [String: Any]` cast fails, and we throw `.noReadableContent`. That path is what `test_pageWithNoArticle` exercises.

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleExtractorTests`
Expected: PASS (4 tests). WKWebView tests take a few seconds each — that's normal.

- [ ] **Step 8: Commit**

```bash
git add Resources/Readability.js Onda/Article/ArticleExtractor.swift \
        OndaTests/Fixtures/article_basic.html OndaTests/ArticleExtractorTests.swift project.yml
git commit -m "feat: article extraction via vendored Readability.js in off-screen WKWebView"
```

---

### Task 4: ArticleSpeechRenderer

**Files:**
- Create: `Onda/Article/ArticleSpeechRenderer.swift`
- Test: `OndaTests/ArticleSpeechRendererTests.swift`

**Interfaces:**
- Consumes: `ParsedCue` (existing, `Onda/Transcription/ParsedCue.swift`).
- Produces:
  - `struct RenderedArticleAudio: Sendable { let fileURL: URL; let duration: TimeInterval; let cues: [ParsedCue] }`
  - `enum ArticleRenderError: Error, Equatable { case noSentences, synthesisFailed, fileWriteFailed }`
  - `protocol ArticleSpeechRendering: Sendable { func render(sentences: [String], voiceIdentifier: String?, outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio }`
  - `final class ArticleSpeechRenderer: ArticleSpeechRendering` (the real engine)
- Task 5 consumes the protocol; Task 6 constructs the real renderer.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ArticleSpeechRendererTests.swift`:

```swift
//  ArticleSpeechRendererTests.swift
import XCTest
import AVFoundation
@testable import Onda

final class ArticleSpeechRendererTests: XCTestCase {
    func test_rendersSentencesToM4AWithMonotonicCues() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }

        let renderer = ArticleSpeechRenderer()
        let result = try await renderer.render(sentences: ["Hello world.", "Goodbye now."],
                                               voiceIdentifier: nil, outputURL: out,
                                               progress: { _ in })

        XCTAssertEqual(result.fileURL, out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].text, "Hello world.")
        XCTAssertEqual(result.cues[0].startTime, 0)
        XCTAssertGreaterThan(result.cues[0].endTime, result.cues[0].startTime)
        XCTAssertGreaterThanOrEqual(result.cues[1].startTime, result.cues[0].endTime)
        XCTAssertEqual(result.duration, result.cues[1].endTime, accuracy: 0.01)
        XCTAssertGreaterThan(result.duration, 0.2, "two spoken sentences can't be near-silent")

        let file = try AVAudioFile(forReading: out)   // decodable AAC container
        XCTAssertGreaterThan(file.length, 0)
    }

    func test_emptySentenceList_throwsNoSentences() async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString).m4a")
        do {
            _ = try await ArticleSpeechRenderer().render(sentences: [], voiceIdentifier: nil,
                                                         outputURL: out, progress: { _ in })
            XCTFail("expected noSentences")
        } catch let e as ArticleRenderError {
            XCTAssertEqual(e, .noSentences)
        } catch { XCTFail("unexpected error \(error)") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleSpeechRendererTests`
Expected: BUILD FAILURE — `cannot find 'ArticleSpeechRenderer' in scope`

- [ ] **Step 3: Implement**

Create `Onda/Article/ArticleSpeechRenderer.swift`:

```swift
//  ArticleSpeechRenderer.swift
import Foundation
import AVFoundation

enum ArticleRenderError: Error, Equatable { case noSentences, synthesisFailed, fileWriteFailed }

struct RenderedArticleAudio: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let cues: [ParsedCue]
}

protocol ArticleSpeechRendering: Sendable {
    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio
}

/// Renders sentences to one AAC (.m4a) file via AVSpeechSynthesizer.write, emitting a
/// sentence-level ParsedCue per utterance from the cumulative frames written. Per-utterance
/// rendering (vs one giant utterance) keeps cue timing exact and failures recoverable.
final class ArticleSpeechRenderer: ArticleSpeechRendering {
    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio {
        guard !sentences.isEmpty else { throw ArticleRenderError.noSentences }
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        let synthesizer = AVSpeechSynthesizer()
        let voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let sink = AudioFileSink(outputURL: outputURL)
        var cues: [ParsedCue] = []
        cues.reserveCapacity(sentences.count)

        for (i, sentence) in sentences.enumerated() {
            let start = sink.secondsWritten
            try await write(sentence, voice: voice, synthesizer: synthesizer, sink: sink)
            cues.append(ParsedCue(startTime: start, endTime: sink.secondsWritten,
                                  text: sentence, speaker: nil))
            progress(Double(i + 1) / Double(sentences.count))
        }
        sink.close()
        return RenderedArticleAudio(fileURL: outputURL, duration: sink.secondsWritten, cues: cues)
    }

    private func write(_ text: String, voice: AVSpeechSynthesisVoice?,
                       synthesizer: AVSpeechSynthesizer, sink: AudioFileSink) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = OnceFlag()
            synthesizer.write(utterance) { buffer in
                guard !done.isTripped else { return }   // late buffers after an error
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    if done.trip() { cont.resume(throwing: ArticleRenderError.synthesisFailed) }
                    return
                }
                if pcm.frameLength == 0 {   // zero-length buffer marks end of utterance
                    if done.trip() { cont.resume() }
                    return
                }
                do { try sink.append(pcm) } catch {
                    if done.trip() { cont.resume(throwing: ArticleRenderError.fileWriteFailed) }
                }
            }
        }
    }
}

/// Accumulates PCM buffers into one AAC file. The synthesizer delivers buffers serially
/// but on a non-main queue; the lock makes cross-thread access (and Sendable) honest.
private final class AudioFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 22_050

    init(outputURL: URL) { self.outputURL = outputURL }

    var secondsWritten: TimeInterval {
        lock.withLock { Double(frames) / sampleRate }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            if file == nil {   // settings must come from the first real buffer's format
                sampleRate = buffer.format.sampleRate
                file = try AVAudioFile(forWriting: outputURL, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount
                ], commonFormat: buffer.format.commonFormat,
                   interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    func close() { lock.withLock { file = nil } }   // releasing AVAudioFile finalizes the container
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    var isTripped: Bool { lock.withLock { tripped } }

    func trip() -> Bool {
        lock.withLock {
            if tripped { return false }
            tripped = true
            return true
        }
    }
}
```

If the compiler demands `@Sendable` on the `write` buffer callback, add it — everything it captures (`sink`, `done`, `cont`) is Sendable.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleSpeechRendererTests`
Expected: PASS (2 tests). The render test speaks two short sentences through the simulator's default voice — allow ~5-15s.

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/ArticleSpeechRenderer.swift OndaTests/ArticleSpeechRendererTests.swift
git commit -m "feat: TTS renderer — sentences to one m4a with per-sentence cue timings"
```

---

### Task 5: ArticleConversionService

**Files:**
- Create: `Onda/Article/ArticleConversionService.swift`
- Test: `OndaTests/ArticleConversionServiceTests.swift`

**Interfaces:**
- Consumes: `ExtractedArticle`, `ArticleExtractionError` (Task 3), `ArticleSpeechRendering`, `RenderedArticleAudio` (Task 4), `SentenceSplitter` (Task 2), models (Task 1), `DownloadManager.fileURL(named:)`, `TranscriptService.persist(cues:for:source:)` via closure, `ParsedCue`.
- Produces (Tasks 6-8, 10 rely on these exact names):
  - `ArticleConversionService.Stage` — `enum { case fetching, synthesizing(Double) }`
  - `ArticleConversionService.Pending: Identifiable, Equatable` — `{ let id: URL; var stage: Stage; var failure: String? }`
  - `var pending: [Pending]`
  - `func add(url: URL)`, `func retry(url: URL)`, `func dismiss(url: URL)`, `func convert(_ url: URL) async` (internal for tests; `add`/`retry` wrap it in a Task)
  - `func articlesPodcast() -> Podcast` (find-or-create, re-subscribes)
  - `static let articlesFeedURL: URL` (`onda-local:articles`)
  - `nonisolated static func audioFileName(for guid: String) -> String` (sanitized + `.m4a`)
  - `init(modelContext:extract:renderer:persistTranscript:)` where `extract: @MainActor @Sendable (URL) async throws -> ExtractedArticle` and `persistTranscript: (Episode, [ParsedCue]) -> Void`

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ArticleConversionServiceTests.swift`:

```swift
//  ArticleConversionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct FakeRenderer: ArticleSpeechRendering {
    var duration: TimeInterval = 3.0
    var cues: [ParsedCue] = [ParsedCue(startTime: 0, endTime: 1.5, text: "One.", speaker: nil),
                             ParsedCue(startTime: 1.5, endTime: 3.0, text: "Two.", speaker: nil)]
    var fails = false

    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio {
        if fails { throw ArticleRenderError.synthesisFailed }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: outputURL)
        progress(1)
        return RenderedArticleAudio(fileURL: outputURL, duration: duration, cues: cues)
    }
}

@MainActor
final class ArticleConversionServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makeService(ctx: ModelContext,
                             extract: @escaping ArticleConversionService.Extract,
                             renderer: ArticleSpeechRendering = FakeRenderer())
        -> ArticleConversionService {
        let ts = TranscriptService(modelContext: ctx, engine: nil,
                                   fetch: { _ in Data() }, localURL: { _ in nil })
        return ArticleConversionService(
            modelContext: ctx, extract: extract, renderer: renderer,
            persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") })
    }

    private let article = ExtractedArticle(title: "The Long Migration", byline: "By Jordan Reyes",
                                           siteName: "Example", textContent: "One. Two.")

    func test_successfulConversion_createsEpisodeWithAllRows() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article })
        let url = URL(string: "https://example.com/terns")!

        await svc.convert(url)

        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
        XCTAssertTrue(pods[0].isLocal)
        XCTAssertTrue(pods[0].isSubscribed)
        XCTAssertEqual(pods[0].title, "Articles")

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1)
        let ep = eps[0]
        XCTAssertEqual(ep.sourceType, "article")
        XCTAssertEqual(ep.title, "The Long Migration")
        XCTAssertEqual(ep.duration, 3.0)
        XCTAssertEqual(ep.podcast?.feedURL, ArticleConversionService.articlesFeedURL)
        XCTAssertEqual(ep.articleSource?.sourceURL, url)
        XCTAssertEqual(ep.downloadedFile?.localFileName,
                       ArticleConversionService.audioFileName(for: ep.guid))
        XCTAssertGreaterThan(ep.downloadedFile?.fileSizeBytes ?? 0, 0)
        XCTAssertEqual(ep.transcript?.source, "tts")
        XCTAssertEqual(ep.transcript?.cues.count, 2)
        XCTAssertTrue(svc.pending.isEmpty)

        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
    }

    func test_extractionFailure_setsFailureAndCreatesNothing() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.noReadableContent })
        let url = URL(string: "https://example.com/paywalled")!

        await svc.convert(url)

        XCTAssertEqual(svc.pending.count, 1)
        XCTAssertEqual(svc.pending[0].failure,
                       ArticleExtractionError.noReadableContent.errorDescription)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Podcast>()).isEmpty,
                      "Articles show must not be created before first success")
    }

    func test_renderFailure_setsFailureAndCreatesNothing() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article },
                              renderer: FakeRenderer(fails: true))
        await svc.convert(URL(string: "https://example.com/x")!)
        XCTAssertNotNil(svc.pending.first?.failure)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    func test_articlesPodcast_reusedAndResubscribed() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx, extract: { _ in self.article })
        let pod = svc.articlesPodcast()
        pod.isSubscribed = false   // user "deleted" the Articles show
        let again = svc.articlesPodcast()
        XCTAssertTrue(again.isSubscribed, "adding an article must revive the show")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertNotNil(again.settings, "settings created with the show for the voice picker")
    }

    func test_audioFileName_sanitizesGuid() {
        XCTAssertEqual(ArticleConversionService.audioFileName(for: "article-AB/12:x"),
                       "article_AB_12_x.m4a")
    }

    func test_dismiss_removesPendingItem() async throws {
        let ctx = try makeContext()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed })
        let url = URL(string: "https://example.com/x")!
        await svc.convert(url)
        XCTAssertEqual(svc.pending.count, 1)
        svc.dismiss(url: url)
        XCTAssertTrue(svc.pending.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleConversionServiceTests`
Expected: BUILD FAILURE — `cannot find 'ArticleConversionService' in scope`

- [ ] **Step 3: Implement**

Create `Onda/Article/ArticleConversionService.swift`:

```swift
//  ArticleConversionService.swift
import Foundation
import SwiftData

/// Orchestrates URL → extracted article → sentences → rendered TTS audio → SwiftData rows.
/// In-flight state is ephemeral (app-kill loses it; the user re-adds the link). Rows are
/// only inserted after the full pipeline succeeds, so a half-finished conversion never
/// shows up as a broken episode.
@MainActor
@Observable
final class ArticleConversionService {
    enum Stage: Equatable { case fetching, synthesizing(Double) }

    struct Pending: Identifiable, Equatable {
        let id: URL
        var stage: Stage = .fetching
        var failure: String?
    }

    typealias Extract = @MainActor @Sendable (URL) async throws -> ExtractedArticle

    static let articlesFeedURL = URL(string: "onda-local:articles")!

    private let modelContext: ModelContext
    private let extract: Extract
    private let renderer: ArticleSpeechRendering
    private let persistTranscript: (Episode, [ParsedCue]) -> Void

    var pending: [Pending] = []

    init(modelContext: ModelContext, extract: @escaping Extract,
         renderer: ArticleSpeechRendering,
         persistTranscript: @escaping (Episode, [ParsedCue]) -> Void) {
        self.modelContext = modelContext
        self.extract = extract
        self.renderer = renderer
        self.persistTranscript = persistTranscript
    }

    func add(url: URL) {
        // Idempotent while in flight; re-adding a failed URL restarts it.
        if let existing = pending.first(where: { $0.id == url }), existing.failure == nil { return }
        pending.removeAll { $0.id == url }
        pending.insert(Pending(id: url), at: 0)
        Task { await convert(url) }
    }

    func retry(url: URL) {
        pending.removeAll { $0.id == url }
        add(url: url)
    }

    func dismiss(url: URL) {
        pending.removeAll { $0.id == url }
    }

    /// Find-or-create the synthetic Articles show. Re-subscribes a previously "deleted"
    /// one — adding an article always makes the show visible again.
    func articlesPodcast() -> Podcast {
        let target = Self.articlesFeedURL
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == target })
        if let existing = try? modelContext.fetch(d).first {
            existing.isSubscribed = true
            return existing
        }
        let pod = Podcast(feedURL: target, title: "Articles", author: "You",
                          artworkURL: nil, category: "Articles", itunesId: nil,
                          isSubscribed: true)
        pod.isLocal = true
        let settings = ShowSettings.makeDefault()
        settings.podcast = pod
        pod.settings = settings
        modelContext.insert(pod)
        return pod
    }

    nonisolated static func audioFileName(for guid: String) -> String {
        guid.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_",
                                  options: .regularExpression) + ".m4a"
    }

    func convert(_ url: URL) async {
        setStage(url, .fetching)
        do {
            let article = try await extract(url)
            let sentences = SentenceSplitter.split(article.textContent)
            guard !sentences.isEmpty else { throw ArticleExtractionError.noReadableContent }

            setStage(url, .synthesizing(0))
            let guid = "article-\(UUID().uuidString)"
            let out = DownloadManager.fileURL(named: Self.audioFileName(for: guid))
            let rendered = try await renderer.render(
                sentences: sentences, voiceIdentifier: currentVoiceIdentifier(),
                outputURL: out,
                progress: { [weak self] p in
                    Task { @MainActor in self?.setStage(url, .synthesizing(p)) }
                })
            insertEpisode(guid: guid, url: url, article: article, rendered: rendered)
            pending.removeAll { $0.id == url }
        } catch {
            setFailure(url, message: (error as? LocalizedError)?.errorDescription
                       ?? "Conversion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - private

    private func insertEpisode(guid: String, url: URL, article: ExtractedArticle,
                               rendered: RenderedArticleAudio) {
        let pod = articlesPodcast()
        let ep = Episode(guid: guid, title: article.title, publishDate: .now,
                         duration: rendered.duration, audioURL: rendered.fileURL,
                         notes: [article.byline, article.siteName].compactMap { $0 }
                             .joined(separator: " — "))
        ep.sourceType = "article"
        modelContext.insert(ep)
        ep.podcast = pod
        pod.episodes.append(ep)

        let src = ArticleSource(sourceURL: url, siteName: article.siteName, addedAt: .now)
        src.episode = ep
        ep.articleSource = src
        modelContext.insert(src)

        let attrs = try? FileManager.default.attributesOfItem(atPath: rendered.fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let file = DownloadedFile(localFileName: Self.audioFileName(for: guid),
                                  fileSizeBytes: size, downloadedAt: .now)
        file.episode = ep
        ep.downloadedFile = file
        modelContext.insert(file)

        persistTranscript(ep, rendered.cues)
        try? modelContext.save()
    }

    /// Reads the voice preference without creating the Articles show (it may not exist yet).
    private func currentVoiceIdentifier() -> String? {
        let target = Self.articlesFeedURL
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == target })
        return (try? modelContext.fetch(d).first)?.settings?.ttsVoiceIdentifier
    }

    /// Upserts: convert(_:) can be entered without a prior add(url:) (tests, queue drain),
    /// so the entry is created here if missing.
    private func setStage(_ url: URL, _ stage: Stage) {
        if let i = pending.firstIndex(where: { $0.id == url }) {
            pending[i].stage = stage
            pending[i].failure = nil
        } else {
            pending.insert(Pending(id: url, stage: stage), at: 0)
        }
    }

    private func setFailure(_ url: URL, message: String) {
        guard let i = pending.firstIndex(where: { $0.id == url }) else { return }
        pending[i].failure = message
    }
}
```

Note: `convert(_:)` is internal (not private) so tests can await it directly without racing `add(url:)`'s fire-and-forget Task.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleConversionServiceTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/ArticleConversionService.swift OndaTests/ArticleConversionServiceTests.swift
git commit -m "feat: article conversion service — extract, synthesize, persist as episode"
```

---

### Task 6: App wiring + Add Article sheet

**Files:**
- Create: `Onda/Article/AddArticleSheet.swift`
- Modify: `Onda/OndaApp.swift` (construct + inject service)
- Modify: `Onda/Shell/LibraryView.swift` (toolbar button + sheet)

**Interfaces:**
- Consumes: `ArticleConversionService` (Task 5), `ArticleExtractor` (Task 3), `ArticleSpeechRenderer` (Task 4), `TranscriptService.persist(cues:for:source:)`.
- Produces: `ArticleConversionService` available via `@Environment(ArticleConversionService.self)` (Task 7 relies on this); `AddArticleSheet` view.

- [ ] **Step 1: Wire the service in OndaApp**

In `Onda/OndaApp.swift`:

Add the state property after `@State private var recommendations: RecommendationService` (line 20):

```swift
    @State private var articles: ArticleConversionService
```

In `init()`, after the `_recommendations = State(...)` assignment (line 66-67), add:

```swift
            let extractor = ArticleExtractor()
            _articles = State(initialValue: ArticleConversionService(
                modelContext: c.mainContext,
                extract: { try await extractor.extract(from: $0) },
                renderer: ArticleSpeechRenderer(),
                persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") }))
```

In `body`, add `.environment(articles)` after `.environment(recommendations)` (line 152).

- [ ] **Step 2: Create AddArticleSheet**

Create `Onda/Article/AddArticleSheet.swift`:

```swift
//  AddArticleSheet.swift
import SwiftUI

struct AddArticleSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(ArticleConversionService.self) private var articles
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a link and Onda reads the article aloud as an episode in your Articles show.")
                    .font(.system(size: 14)).foregroundStyle(theme.color(.textSecondary))
                TextField("https://…", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go).onSubmit { submit() }
                    .accessibilityIdentifier("add-article-url")
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
                if let error {
                    Text(error).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.color(.accent))
                }
                Button { submit() } label: {
                    Text("ADD ARTICLE")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(theme.color(.accent)).brutalBorder(width: 2)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(20)
            .background(theme.color(.bg))
            .navigationTitle("Add Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else {
            error = "Enter a full link starting with http:// or https://"
            return
        }
        articles.add(url: url)
        dismiss()
    }
}
```

- [ ] **Step 3: Add the Library toolbar button**

In `Onda/Shell/LibraryView.swift`:

Add state after `@State private var showClips = false` (line 35):

```swift
    @State private var showAddArticle = false
```

In the header `HStack`, insert a button between the CLIPS button and the search button (after line 56):

```swift
                        Button { showAddArticle = true } label: {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Add Article")
```

Add the sheet after `.sheet(isPresented: $showClips) { ClipsView() }` (line 113):

```swift
            .sheet(isPresented: $showAddArticle) { AddArticleSheet() }
```

- [ ] **Step 4: Build + lint**

Run: `xcodegen generate && xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' && swiftlint lint --quiet`
Expected: BUILD SUCCEEDED, no new lint violations.

- [ ] **Step 5: Commit**

```bash
git add Onda/OndaApp.swift Onda/Article/AddArticleSheet.swift Onda/Shell/LibraryView.swift
git commit -m "feat: Add Article sheet and service wiring"
```

---

### Task 7: Articles show UI — pending rows + isLocal guards

**Files:**
- Create: `Onda/Article/ArticlePendingRow.swift`
- Modify: `Onda/Library/EpisodeListView.swift` (pending rows, isLocal refresh guard, delete label)
- Modify: `Onda/Shell/LibraryView.swift` (isLocal context menu)
- Modify: `Onda/Services/SubscriptionService.swift` (refresh guard)
- Test: extend `OndaTests/ArticleConversionServiceTests.swift` (refresh-guard test lives in `OndaTests/SubscriptionServiceTests.swift`)

**Interfaces:**
- Consumes: `ArticleConversionService.pending/.retry(url:)/.dismiss(url:)`, `Podcast.isLocal`.
- Produces: `ArticlePendingRow(item:onRetry:onDismiss:)` view; `SubscriptionService.refreshEpisodes(for:)` early-returns for local shows.

- [ ] **Step 1: Write the failing refresh-guard test**

Append to `OndaTests/SubscriptionServiceTests.swift` (inside the class, using its existing `context()` helper; note the file's `StubFeeds` takes a `ParsedFeed`):

```swift
    func test_refreshEpisodes_localShow_neverTouchesTheFeed() async throws {
        struct ThrowingFeeds: FeedFetching {
            func fetchFeed(_ url: URL) async throws -> ParsedFeed {
                XCTFail("local shows must not be fetched")
                throw NSError(domain: "test", code: 1)
            }
        }
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: ThrowingFeeds())
        let pod = Podcast(feedURL: URL(string: "onda-local:articles")!, title: "Articles",
                          author: "You", artworkURL: nil, category: "Articles", itunesId: nil,
                          isSubscribed: true)
        pod.isLocal = true
        ctx.insert(pod)
        try await svc.refreshEpisodes(for: pod)   // must be a silent no-op
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SubscriptionServiceTests/test_refreshEpisodes_localShow_neverTouchesTheFeed`
Expected: FAIL — `XCTFail("local shows must not be fetched")` fires (the `onda-local:` fetch attempt reaches the stub).

- [ ] **Step 3: Add the guard**

In `Onda/Services/SubscriptionService.swift`, at the top of `refreshEpisodes(for:)` (line ~97) add:

```swift
        guard !podcast.isLocal else { return }   // synthetic shows have no feed to poll
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SubscriptionServiceTests`
Expected: PASS (all tests in class, including the new one)

- [ ] **Step 5: Create ArticlePendingRow**

Create `Onda/Article/ArticlePendingRow.swift`:

```swift
//  ArticlePendingRow.swift
import SwiftUI

/// In-flight conversion row shown at the top of the Articles show's episode list.
/// Backed by ArticleConversionService's ephemeral state, not a real Episode.
struct ArticlePendingRow: View {
    @Environment(AppTheme.self) private var theme
    let item: ArticleConversionService.Pending
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.id.host() ?? item.id.absoluteString)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.color(.text))
                .lineLimit(1)
            if let failure = item.failure {
                Text(failure).font(.system(size: 13))
                    .foregroundStyle(theme.color(.accent))
                HStack(spacing: 10) {
                    Button("RETRY") { onRetry() }
                    Button("DISMISS") { onDismiss() }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.color(.textSecondary))
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stageLabel).font(.system(size: 13))
                        .foregroundStyle(theme.color(.textTertiary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
    }

    private var stageLabel: String {
        switch item.stage {
        case .fetching: return "Fetching article…"
        case .synthesizing(let p): return "Synthesizing speech… \(Int(p * 100))%"
        }
    }
}
```

- [ ] **Step 6: Surface pending rows + isLocal tweaks in EpisodeListView**

In `Onda/Library/EpisodeListView.swift`:

Add the environment after `@Environment(SearchIndexBox.self)` (line 12):

```swift
    @Environment(ArticleConversionService.self) private var articles
```

Inside the `List`, directly before `ForEach(displayedEpisodes)` (line 62), add:

```swift
            if podcast.isLocal {
                ForEach(articles.pending) { item in
                    ArticlePendingRow(item: item,
                                      onRetry: { articles.retry(url: item.id) },
                                      onDismiss: { articles.dismiss(url: item.id) })
                        .listRowBackground(theme.color(.bg))
                        .listRowSeparator(.hidden)
                }
            }
```

In `refresh()` (line 165) add a guard as the first line:

```swift
        guard !podcast.isLocal else { return }
```

In `header` (line 177), make the button label conditional:

```swift
                Button(podcast.isLocal ? "Delete Show" : "Unsubscribe") {
                    subscriptions.unsubscribe(podcast); dismiss()
                }
```

(`unsubscribe` already does the right thing for a local show: hides it and frees downloads; `articlesPodcast()` re-subscribes on the next added article.)

- [ ] **Step 7: isLocal context menu in LibraryView**

In `Onda/Shell/LibraryView.swift`, replace the body of `contextMenu(for:)` (lines 197-208) with:

```swift
    @ViewBuilder private func contextMenu(for show: Podcast) -> some View {
        if !show.isLocal {
            Button { checkUpdates(show) } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
            Button { downloadLatest(show) } label: { Label("Download Latest", systemImage: "arrow.down.circle") }
        }
        Button { settingsPodcast = show } label: { Label("Show Settings", systemImage: "gearshape") }
        Button { subscriptions.markAllPlayed(for: show) } label: {
            Label("Mark All Played", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { unsubscribeTarget = show } label: {
            Label(show.isLocal ? "Delete Articles Show" : "Unsubscribe", systemImage: "trash")
        }
    }
```

- [ ] **Step 8: Build + lint + full test pass**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests && swiftlint lint --quiet`
Expected: all unit tests pass; no new lint violations.

- [ ] **Step 9: Commit**

```bash
git add Onda/Article/ArticlePendingRow.swift Onda/Library/EpisodeListView.swift \
        Onda/Shell/LibraryView.swift Onda/Services/SubscriptionService.swift \
        OndaTests/SubscriptionServiceTests.swift
git commit -m "feat: Articles show UI — in-flight rows, local-show guards and labels"
```

---

### Task 8: Voice picker in ShowSettingsSheet

**Files:**
- Modify: `Onda/Settings/ShowSettingsSheet.swift`

**Interfaces:**
- Consumes: `Podcast.isLocal`, `ShowSettings.ttsVoiceIdentifier` (Task 1).
- Produces: a "Article Voice" section visible only on the Articles show.

- [ ] **Step 1: Implement the voice section**

In `Onda/Settings/ShowSettingsSheet.swift`:

Add the import at the top (after `import SwiftUI`):

```swift
import AVFoundation
```

Add state inside the struct (after the `speedSteps` property, line 16):

```swift
    @State private var showAllVoiceLanguages = false
```

In `body`, insert a new section before `section("Playback")` (line 22):

```swift
                    if podcast.isLocal {
                        section("Article Voice") { voiceSection }
                    }
```

Add these members at the bottom of the struct (before the closing brace):

```swift
    private var availableVoices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let filtered = showAllVoiceLanguages ? all : all.filter { $0.language.hasPrefix(lang) }
        return filtered.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    @ViewBuilder private var voiceSection: some View {
        row("Voice") {
            Menu {
                Picker("Voice", selection: Binding(
                    get: { s.ttsVoiceIdentifier ?? "" },
                    set: { s.ttsVoiceIdentifier = $0.isEmpty ? nil : $0 })) {
                    Text("System Default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
            } label: {
                Text(selectedVoiceName)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.color(.text))
            }
        }
        Toggle("All Languages", isOn: $showAllVoiceLanguages)
            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
        Text("New articles are narrated with this voice. Already-converted episodes keep theirs.")
            .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
    }

    private var selectedVoiceName: String {
        guard let id = s.ttsVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: id) else { return "System Default" }
        return voice.name
    }
```

- [ ] **Step 2: Build + lint**

Run: `xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' && swiftlint lint --quiet`
Expected: BUILD SUCCEEDED, no new violations.

- [ ] **Step 3: Commit**

```bash
git add Onda/Settings/ShowSettingsSheet.swift
git commit -m "feat: TTS voice picker in Articles show settings"
```

---

### Task 9: PendingArticlesQueue (App Group handoff file)

**Files:**
- Create: `Onda/Article/PendingArticlesQueue.swift`
- Test: `OndaTests/PendingArticlesQueueTests.swift`

**Interfaces:**
- Produces: `struct PendingArticlesQueue: Sendable` with `static let appGroupID = "group.com.chasegilliam.onda"`, `static var standard: PendingArticlesQueue`, `init(containerURL: URL?)`, `func append(_ url: URL)`, `func drain() -> [URL]`. Task 10's extension calls `append`; Task 10's app wiring calls `drain`.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/PendingArticlesQueueTests.swift`:

```swift
//  PendingArticlesQueueTests.swift
import XCTest
@testable import Onda

final class PendingArticlesQueueTests: XCTestCase {
    private func tempQueue() -> PendingArticlesQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingArticlesQueue(containerURL: dir)
    }

    func test_appendThenDrain_returnsURLsInOrderAndClears() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        let b = URL(string: "https://ex.com/b")!
        q.append(a)
        q.append(b)
        XCTAssertEqual(q.drain(), [a, b])
        XCTAssertEqual(q.drain(), [], "drain must clear the file")
    }

    func test_append_dedupesIdenticalURL() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        q.append(a)
        q.append(a)
        XCTAssertEqual(q.drain(), [a])
    }

    func test_nilContainer_isSafeNoOp() {
        let q = PendingArticlesQueue(containerURL: nil)
        q.append(URL(string: "https://ex.com/a")!)
        XCTAssertEqual(q.drain(), [])
    }

    func test_corruptFile_drainsEmpty() {
        let q = tempQueue()
        q.append(URL(string: "https://ex.com/a")!)
        let file = q.containerURL!.appendingPathComponent("pending-articles.json")
        try! Data("not json".utf8).write(to: file)
        XCTAssertEqual(q.drain(), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/PendingArticlesQueueTests`
Expected: BUILD FAILURE — `cannot find 'PendingArticlesQueue' in scope`

- [ ] **Step 3: Implement**

Create `Onda/Article/PendingArticlesQueue.swift`:

```swift
//  PendingArticlesQueue.swift
import Foundation

/// Share-extension → app handoff: the extension appends shared URLs to a JSON file in
/// the App Group container; the app drains it on foreground. This file is the one piece
/// of feature state persisted outside SwiftData — the two processes share no database,
/// and the app may not be running when a share happens.
///
/// NOTE: compiled into BOTH the Onda app target and OndaShareExtension (see project.yml) —
/// keep it dependency-free (Foundation only).
struct PendingArticlesQueue: Sendable {
    static let appGroupID = "group.com.chasegilliam.onda"

    static var standard: PendingArticlesQueue {
        PendingArticlesQueue(containerURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID))
    }

    let containerURL: URL?   // nil when the entitlement is missing (e.g. unit tests)

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("pending-articles.json")
    }

    func append(_ url: URL) {
        guard let fileURL else { return }
        var urls = load()
        guard !urls.contains(url) else { return }
        urls.append(url)
        if let data = try? JSONEncoder().encode(urls) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func drain() -> [URL] {
        guard let fileURL else { return [] }
        let urls = load()
        try? FileManager.default.removeItem(at: fileURL)
        return urls
    }

    private func load() -> [URL] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([URL].self, from: data)) ?? []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/PendingArticlesQueueTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/PendingArticlesQueue.swift OndaTests/PendingArticlesQueueTests.swift
git commit -m "feat: app-group pending-articles queue for share-extension handoff"
```

---

### Task 10: Share Extension target + foreground drain

**Files:**
- Create: `OndaShareExtension/ShareViewController.swift`
- Modify: `project.yml` (new target, entitlements on both targets, embed dependency)
- Modify: `Onda/OndaApp.swift` (drain queue on foreground)

**Interfaces:**
- Consumes: `PendingArticlesQueue` (Task 9), `ArticleConversionService.add(url:)` (Task 5).
- Produces: `OndaShareExtension` app-extension target accepting shared web URLs.

- [ ] **Step 1: project.yml changes**

In `project.yml`, inside the `Onda` target: add entitlements and the embed dependency so the whole target section's `dependencies`/`entitlements` read:

```yaml
    dependencies:
      - sdk: libsqlite3.tbd
      - target: OndaShareExtension
    entitlements:
      path: Onda/Onda.entitlements
      properties:
        com.apple.security.application-groups: [group.com.chasegilliam.onda]
```

Add a new target at the bottom of `targets:`:

```yaml
  OndaShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - OndaShareExtension
      - Onda/Article/PendingArticlesQueue.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.chasegilliam.Onda.ShareExtension
        INFOPLIST_KEY_CFBundleDisplayName: Onda
    info:
      path: OndaShareExtension/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsWebURLWithMaxCount: 1
              NSExtensionActivationSupportsWebPageWithMaxCount: 1
    entitlements:
      path: OndaShareExtension/OndaShareExtension.entitlements
      properties:
        com.apple.security.application-groups: [group.com.chasegilliam.onda]
```

(XcodeGen generates both `.entitlements` files and the extension's `Info.plist` from these blocks — do not create them by hand.)

- [ ] **Step 2: Create ShareViewController**

Create `OndaShareExtension/ShareViewController.swift`:

```swift
//  ShareViewController.swift
//  OndaShareExtension — no UI, no heavy work: grab the shared URL, queue it for the
//  main app (which does extraction + TTS on next foreground), and dismiss.
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        handleShare()
    }

    private func handleShare() {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            complete()
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            if let url = item as? URL, let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                PendingArticlesQueue.standard.append(url)
            }
            DispatchQueue.main.async { self?.complete() }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
```

- [ ] **Step 3: Drain the queue on foreground**

In `Onda/OndaApp.swift`, in the `.onChange(of: scenePhase)` handler (line 154-160), add the drain before the refresh call so the `.active` branch reads:

```swift
                    if phase == .active {
                        for url in PendingArticlesQueue.standard.drain() { articles.add(url: url) }
                        Task { [refresh] in await refresh.refreshAll() }
                    } else if phase == .background {
                        refresh.scheduleBackgroundRefresh()
                    }
```

- [ ] **Step 4: Regenerate, build everything, run all tests**

Run: `xcodegen generate && xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests && swiftlint lint --quiet`
Expected: extension + app both build, all unit tests pass, no new lint violations. (If code signing complains about the App Group on the simulator, the group entitlement is ignored there — the build must still succeed.)

- [ ] **Step 5: Commit**

```bash
git add project.yml OndaShareExtension/ Onda/OndaApp.swift
git commit -m "feat: share extension — queue shared article links for conversion"
```

---

### Task 11: End-to-end verification (manual, simulator)

**Files:** none (verification only)

- [ ] **Step 1: Run the app in the simulator**

Launch Onda on the iPhone 17 simulator. On the Library tab, tap the Add Article button, paste a real article URL (e.g. a Wikipedia article or blog post), tap ADD ARTICLE.

Expected: sheet dismisses; an "Articles" show appears in the Library; opening it shows a pending row progressing fetch → synthesize; on completion a real episode appears with a duration.

- [ ] **Step 2: Verify playback + transcript**

Play the episode. Expected: audio plays through the normal player; the transcript view shows the article sentences; tapping a sentence seeks to it; scrubbing works; the episode shows as Downloaded.

- [ ] **Step 3: Verify voice picker**

Open the Articles show's settings. Expected: "Article Voice" section with a voice menu; pick a non-default voice, add a second article, and confirm the new episode uses the new voice while the first keeps the old one.

- [ ] **Step 4: Verify failure path**

Add a URL that isn't an article (e.g. `https://example.com`). Expected: pending row shows "No readable article found on that page." with working RETRY and DISMISS.

- [ ] **Step 5: Share extension (device or share-capable simulator)**

In Safari (simulator), share a page → Onda. Reopen Onda. Expected: conversion starts on foreground. (If the share sheet doesn't offer Onda on the simulator, verify on a device; the queue-file mechanics are already unit-tested.)

- [ ] **Step 6: Final commit if fixes were needed**

Any fixes discovered during verification get their own focused commits.
