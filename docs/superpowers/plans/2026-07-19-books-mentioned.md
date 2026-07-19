# Books Mentioned Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-episode, user-initiated book extraction ("what was that book in THIS episode?") launched from a book icon in the player, per `docs/superpowers/specs/2026-07-19-books-mentioned-design.md`.

**Architecture:** A candidates→verification funnel: show-notes links + text patterns + on-device Foundation Models extraction feed one OpenLibrary verification gate; only verified books persist (`BookMention` SwiftData model) and render in a player-presented BooksSheet. Strictly one episode per invocation; private feeds excluded.

**Tech Stack:** Swift 6 / SwiftUI, SwiftData, FoundationModels (iOS 26, availability-gated), NaturalLanguage, XcodeGen, SwiftLint, XCTest.

## Global Constraints

- After adding/removing any file: `xcodegen generate` (never hand-edit project.pbxproj; commits that add files stage it).
- Build verify: `xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` → `** BUILD SUCCEEDED **`.
- Test command shape: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/<Class> 2>&1 | grep -E "error:|passed|failed|\*\* TEST"`.
- Fonts: `.scaledFont` only; small white text on accent fills uses `theme.color(.accentStrong)`; interactive controls ≥44pt with a11y labels.
- SwiftLint clean on touched files (`swiftlint lint --quiet <files>`), aside from the repo's grandfathered warnings.
- **No open-ended mode**: every API in this plan takes exactly one `Episode`. Do not add batch/library-wide entry points.
- Privacy: no candidate generation for `podcast.isPrivateFeed == true`; only candidate titles (never transcript text) go to the network.
- Commit after every task. Do NOT push; the operator deploys.

---

### Task 1: Parser captures note links; Episode stores them

**Files:**
- Modify: `Onda/Networking/RSSFeedParser.swift` (working item struct, `handleItemEndElement` description case, `buildFeed`, `ParsedEpisode`)
- Modify: `Onda/Models/Episode.swift` (new stored property + init param)
- Modify: `Onda/Services/SubscriptionService.swift` (`refreshEpisodes` Episode construction)
- Test: `OndaTests/RSSFeedParserTests.swift`

**Interfaces:**
- Produces: `ParsedEpisode.noteLinks: [URL]`, `Episode.noteLinks: [URL]` (default `[]`), Episode init gains `noteLinks: [URL] = []`.

- [ ] **Step 1: Write the failing test**

Append to `OndaTests/RSSFeedParserTests.swift` (inside the test class, matching its existing fixture style — it parses XML strings via `RSSFeedParser().parse(Data(xml.utf8))`):

```swift
    func test_parse_capturesNoteLinksBeforeStrippingHTML() throws {
        let xml = """
        <rss><channel><title>Show</title>
        <item><title>Ep</title><guid>g1</guid>
        <description><![CDATA[Great chat. <a href="https://www.amazon.com/dp/0735211299">Atomic Habits</a> \
        and <a href='https://bookshop.org/p/books/deep-work-cal-newport/8339063'>Deep Work</a>]]></description>
        <enclosure url="https://ex.com/e1.mp3" type="audio/mpeg" length="1"/>
        </item></channel></rss>
        """
        let feed = try XCTUnwrap(RSSFeedParser().parse(Data(xml.utf8)))
        let ep = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(ep.noteLinks.map(\.absoluteString),
                       ["https://www.amazon.com/dp/0735211299",
                        "https://bookshop.org/p/books/deep-work-cal-newport/8339063"])
        XCTAssertFalse(ep.notes.contains("<a "), "notes stay stripped plain text")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run the RSSFeedParserTests test command. Expected: build error — `ParsedEpisode` has no `noteLinks`.

- [ ] **Step 3: Implement**

In `Onda/Networking/RSSFeedParser.swift`:

(a) `ParsedEpisode` gains a field (after `notes`):

```swift
    let notes: String
    var noteLinks: [URL] = []
```

(b) The working item struct — the type of `current` inside `FeedDelegate` (it already has `title/guid/notes/pubDate/duration/audioURL/...` fields) — gains:

```swift
        var noteLinks: [URL] = []
```

(c) In `handleItemEndElement`, the description case captures hrefs from the RAW value before stripping:

```swift
        case "description", "itunes:summary":
            if current?.notes.isEmpty ?? true {
                current?.noteLinks = FeedDelegate.extractLinks(value)
                current?.notes = stripHTML(value)
            }
```

(d) Add to `FeedDelegate` (next to `stripHTML`):

```swift
    /// Hrefs from raw description HTML, captured BEFORE stripHTML destroys them —
    /// the Books Mentioned link tier reads Amazon/Bookshop/Goodreads URLs from these.
    static func extractLinks(_ raw: String) -> [URL] {
        var links: [URL] = []
        var search = raw[raw.startIndex...]
        while let r = search.range(of: "href=[\"']([^\"']+)[\"']", options: .regularExpression) {
            let match = search[r]
            let urlText = match.dropFirst(6).dropLast()   // strip href=" and trailing quote
            if let url = URL(string: String(urlText)), url.scheme?.hasPrefix("http") == true {
                links.append(url)
            }
            search = search[r.upperBound...]
        }
        return links
    }
```

(e) In `buildFeed`, pass it through:

```swift
            return ParsedEpisode(guid: guid, title: it.title, publishDate: it.pubDate,
                                 duration: it.duration, audioURL: audio, notes: it.notes,
                                 noteLinks: it.noteLinks,
                                 chaptersURL: it.chaptersURL,
                                 transcriptURL: it.transcriptURL, transcriptType: it.transcriptType)
```

(`ParsedEpisode` is a struct with a memberwise init — placing `noteLinks:` after `notes:` matches the field order above. If other `ParsedEpisode(` constructions exist (grep for them — e.g. test helpers, article conversion), the `= []` default keeps them compiling; only add the label where noteLinks are actually available.)

In `Onda/Models/Episode.swift`: add after `var notes: String`:

```swift
    var noteLinks: [URL] = []   // hrefs from the feed description — Books Mentioned link tier
```

and in the init signature after `notes: String,` add `noteLinks: [URL] = [],` with `self.noteLinks = noteLinks` in the body.

In `Onda/Services/SubscriptionService.swift`, `refreshEpisodes(for:)`, the `Episode(` construction gains `noteLinks: pe.noteLinks,` after `notes: pe.notes,`.

- [ ] **Step 4: Run tests to verify pass**

Run RSSFeedParserTests command → all pass. Then the FULL unit suite (`-only-testing:OndaTests`) → `** TEST SUCCEEDED **` (schema change: `noteLinks` is additive with a default — lightweight migration).

- [ ] **Step 5: Lint + commit**

```bash
swiftlint lint --quiet Onda/Networking/RSSFeedParser.swift Onda/Models/Episode.swift Onda/Services/SubscriptionService.swift OndaTests/RSSFeedParserTests.swift
git add Onda/Networking/RSSFeedParser.swift Onda/Models/Episode.swift Onda/Services/SubscriptionService.swift OndaTests/RSSFeedParserTests.swift
git commit -m "feat: capture show-notes hrefs as Episode.noteLinks (Books Mentioned tier 1 input)"
```

---

### Task 2: BookMention model

**Files:**
- Create: `Onda/Models/BookMention.swift`
- Modify: `Onda/Models/ModelSchema.swift`, `Onda/Models/Episode.swift`
- Test: `OndaTests/ModelTests.swift`

**Interfaces:**
- Produces: `BookMention` @Model (`workKey/title/author/coverURL/sourceTier/timestamp/createdAt/episode`), `Episode.bookMentions: [BookMention]` (cascade).

- [ ] **Step 1: Write the failing test**

Append to `OndaTests/ModelTests.swift` (match its existing in-memory-container helper style):

```swift
    func test_bookMention_roundTripsAndCascadesFromEpisode() throws {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ctx.insert(ep)
        let book = BookMention(workKey: "OL123W", title: "Atomic Habits", author: "James Clear",
                               coverURL: nil, sourceTier: "link", timestamp: nil)
        book.episode = ep; ep.bookMentions.append(book)
        ctx.insert(book); try ctx.save()

        ctx.delete(ep); try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BookMention>()).count, 0,
                       "book mentions cascade with their episode")
    }
```

- [ ] **Step 2: Run to verify it fails** — ModelTests command; expected: `cannot find 'BookMention'`.

- [ ] **Step 3: Implement**

Create `Onda/Models/BookMention.swift`:

```swift
//  BookMention.swift
//  A VERIFIED book reference extracted from one episode (Books Mentioned feature).
//  Only catalog-verified books are ever persisted — see the design spec's precision rule.
import Foundation
import SwiftData

@Model
final class BookMention {
    var workKey: String          // OpenLibrary work key — per-episode dedupe key
    var title: String            // canonical title from the catalog, not the raw candidate
    var author: String?
    var coverURL: URL?
    var sourceTier: String       // "link" | "notes" | "transcript"
    var timestamp: TimeInterval? // feed-seconds; transcript-derived mentions only
    var createdAt: Date

    var episode: Episode?

    init(workKey: String, title: String, author: String?, coverURL: URL?,
         sourceTier: String, timestamp: TimeInterval?, createdAt: Date = .now) {
        self.workKey = workKey
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.sourceTier = sourceTier
        self.timestamp = timestamp
        self.createdAt = createdAt
    }
}
```

`Onda/Models/Episode.swift` — add with the other relationships:

```swift
    @Relationship(deleteRule: .cascade, inverse: \BookMention.episode)
    var bookMentions: [BookMention] = []
```

`Onda/Models/ModelSchema.swift` — append `BookMention.self` to `ondaSchema`.

- [ ] **Step 4: `xcodegen generate`, run ModelTests + full OndaTests** → all pass.

- [ ] **Step 5: Commit**

```bash
git add Onda/Models/BookMention.swift Onda/Models/Episode.swift Onda/Models/ModelSchema.swift OndaTests/ModelTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: BookMention model (verified per-episode book references)"
```

---

### Task 3: Candidate types + link parser (tier 1)

**Files:**
- Create: `Onda/Books/BookCandidate.swift`, `Onda/Books/BookLinkParser.swift`
- Test: `OndaTests/BookLinkParserTests.swift`

**Interfaces:**
- Produces:
  - `struct BookCandidate: Equatable, Sendable { var title: String?; var author: String?; var isbnOrASIN: String?; var timestamp: TimeInterval?; var sourceTier: String }`
  - `enum BookLinkParser { static func candidates(from links: [URL]) -> [BookCandidate] }`

- [ ] **Step 1: Write the failing test**

Create `OndaTests/BookLinkParserTests.swift`:

```swift
//  BookLinkParserTests.swift
import XCTest
@testable import Onda

final class BookLinkParserTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func test_amazonDP_yieldsASINCandidate() {
        let c = BookLinkParser.candidates(from: [url("https://www.amazon.com/dp/0735211299?tag=aff-20")])
        XCTAssertEqual(c, [BookCandidate(title: nil, author: nil, isbnOrASIN: "0735211299",
                                         timestamp: nil, sourceTier: "link")])
    }

    func test_amazonGPProduct_yieldsASIN() {
        let c = BookLinkParser.candidates(from: [url("https://amazon.com/gp/product/B07D23CFGR")])
        XCTAssertEqual(c.first?.isbnOrASIN, "B07D23CFGR")
    }

    func test_bookshopSlug_yieldsTitleWords() {
        let c = BookLinkParser.candidates(from: [url("https://bookshop.org/p/books/deep-work-cal-newport/8339063")])
        XCTAssertEqual(c.first?.title, "deep work cal newport")
        XCTAssertEqual(c.first?.sourceTier, "link")
    }

    func test_goodreadsSlug_yieldsTitleWords() {
        let c = BookLinkParser.candidates(from: [url("https://www.goodreads.com/book/show/40121378-atomic-habits")])
        XCTAssertEqual(c.first?.title, "atomic habits")
    }

    func test_irrelevantLinks_yieldNothing() {
        let c = BookLinkParser.candidates(from: [url("https://patreon.com/show"),
                                                 url("https://amazon.com/some-page")])
        XCTAssertTrue(c.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify fail** (BookLinkParserTests command; needs `xcodegen generate` first for the new files) — expected: cannot find `BookLinkParser`.

- [ ] **Step 3: Implement**

`Onda/Books/BookCandidate.swift`:

```swift
//  BookCandidate.swift
//  An UNVERIFIED book reference from any extraction tier. Candidates only ever become
//  visible after the OpenLibrary verification gate (BookVerifier).
import Foundation

struct BookCandidate: Equatable, Sendable {
    var title: String?
    var author: String?
    var isbnOrASIN: String?
    var timestamp: TimeInterval?
    var sourceTier: String   // "link" | "notes" | "transcript"
}
```

`Onda/Books/BookLinkParser.swift`:

```swift
//  BookLinkParser.swift
//  Tier 1: book-retailer URLs from show notes — the highest-precision candidate source.
import Foundation

enum BookLinkParser {
    static func candidates(from links: [URL]) -> [BookCandidate] {
        links.compactMap { candidate(from: $0) }
    }

    private static func candidate(from url: URL) -> BookCandidate? {
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.contains("amazon.") {
            // /dp/<ASIN> or /gp/product/<ASIN>
            if let i = parts.firstIndex(of: "dp"), parts.indices.contains(i + 1) {
                return BookCandidate(title: nil, author: nil, isbnOrASIN: parts[i + 1],
                                     timestamp: nil, sourceTier: "link")
            }
            if let i = parts.firstIndex(of: "product"), parts.indices.contains(i + 1),
               i > 0, parts[i - 1] == "gp" {
                return BookCandidate(title: nil, author: nil, isbnOrASIN: parts[i + 1],
                                     timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        if host.contains("bookshop.org") {
            // /p/books/<title-slug>/<id>
            if let i = parts.firstIndex(of: "books"), parts.indices.contains(i + 1) {
                return BookCandidate(title: slugWords(parts[i + 1]), author: nil,
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        if host.contains("goodreads.com") {
            // /book/show/<id>-<title-slug>
            if let i = parts.firstIndex(of: "show"), parts.indices.contains(i + 1) {
                let slug = parts[i + 1].drop { $0.isNumber || $0 == "-" }
                guard !slug.isEmpty else { return nil }
                return BookCandidate(title: slugWords(String(slug)), author: nil,
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        return nil
    }

    private static func slugWords(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run tests** → 5/5 pass. **Step 5: Commit**

```bash
git add Onda/Books OndaTests/BookLinkParserTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: BookCandidate + tier-1 link parser (Amazon/Bookshop/Goodreads)"
```

---

### Task 4: Pattern extractor (tier 2)

**Files:**
- Create: `Onda/Books/BookPatternExtractor.swift`
- Test: `OndaTests/BookPatternExtractorTests.swift`

**Interfaces:**
- Produces: `struct BookPatternExtractor { var isPersonName: (String) -> Bool; func candidates(fromNotes: String) -> [BookCandidate]; func candidates(fromCues: [(text: String, start: TimeInterval)]) -> [BookCandidate] }`
- The person check is injected so tests never touch NLTagger (its models are flaky in simulators — see `docs/BUGS.md` #2). Production wiring (Task 7) passes an NLTagger-backed closure.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/BookPatternExtractorTests.swift`:

```swift
//  BookPatternExtractorTests.swift
import XCTest
@testable import Onda

final class BookPatternExtractorTests: XCTestCase {
    // People named Cal Newport / James Clear exist; "Next Week" is not a person.
    private let extractor = BookPatternExtractor(isPersonName: { name in
        ["Cal Newport", "James Clear"].contains(name)
    })

    func test_quotedTitleByPerson_inNotes() {
        let c = extractor.candidates(fromNotes: #"We loved "Deep Work" by Cal Newport this week."#)
        XCTAssertEqual(c, [BookCandidate(title: "Deep Work", author: "Cal Newport",
                                         isbnOrASIN: nil, timestamp: nil, sourceTier: "notes")])
    }

    func test_byNonPerson_rejected() {
        let c = extractor.candidates(fromNotes: #"More episodes "Coming Soon" by Next Week."#)
        XCTAssertTrue(c.isEmpty, "the by-clause must name a verified person")
    }

    func test_readingListBlock_inNotes() {
        let notes = """
        Great episode!
        Books mentioned:
        Atomic Habits — James Clear
        Deep Work — Cal Newport
        """
        let c = extractor.candidates(fromNotes: notes)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].title, "Atomic Habits")
        XCTAssertEqual(c[0].author, "James Clear")
    }

    func test_cueMatches_carryTimestamps() {
        let cues = [(text: #"I just finished "Atomic Habits" by James Clear"#, start: 812.0)]
        let c = extractor.candidates(fromCues: cues)
        XCTAssertEqual(c.first?.timestamp, 812.0)
        XCTAssertEqual(c.first?.sourceTier, "transcript")
    }
}
```

- [ ] **Step 2: Run to verify fail** → cannot find `BookPatternExtractor`.

- [ ] **Step 3: Implement**

Create `Onda/Books/BookPatternExtractor.swift`:

```swift
//  BookPatternExtractor.swift
//  Tier 2: explicit textual book references — quoted "Title" by Person, and
//  "Books mentioned:" list blocks. High precision, low recall, no ML beyond the
//  injected person check (NLTagger in production; a fixture closure in tests).
import Foundation

struct BookPatternExtractor {
    /// True when the string is a person's name. Injected: NLTagger-backed in the app,
    /// deterministic in tests (NL models are flaky in simulators — docs/BUGS.md #2).
    var isPersonName: (String) -> Bool

    func candidates(fromNotes notes: String) -> [BookCandidate] {
        quotedByPatterns(in: notes, tier: "notes", timestamp: nil)
            + readingListBlock(in: notes)
    }

    func candidates(fromCues cues: [(text: String, start: TimeInterval)]) -> [BookCandidate] {
        cues.flatMap { quotedByPatterns(in: $0.text, tier: "transcript", timestamp: $0.start) }
    }

    // "<Title>" by <Capitalized Name>
    private func quotedByPatterns(in text: String, tier: String,
                                  timestamp: TimeInterval?) -> [BookCandidate] {
        let pattern = "[\"\u{201C}]([^\"\u{201C}\u{201D}]{2,80})[\"\u{201D}]\\s+by\\s+([A-Z][\\w.\\-]+(?:\\s+[A-Z][\\w.\\-]+){0,3})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let author = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                guard isPersonName(author) else { return nil }
                return BookCandidate(title: title, author: author, isbnOrASIN: nil,
                                     timestamp: timestamp, sourceTier: tier)
            }
    }

    // "Books mentioned:" / "Reading list:" header, then "Title — Author" (or "Title - Author") lines.
    private func readingListBlock(in notes: String) -> [BookCandidate] {
        let lines = notes.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { line in
            let l = line.lowercased()
            return l.contains("books mentioned") || l.contains("reading list")
        }) else { return [] }
        var out: [BookCandidate] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }   // blank line ends the block
            let separators = [" \u{2014} ", " \u{2013} ", " - "]
            guard let sep = separators.first(where: { trimmed.contains($0) }) else { continue }
            let parts = trimmed.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            out.append(BookCandidate(title: parts[0].trimmingCharacters(in: .whitespaces),
                                     author: parts[1].trimmingCharacters(in: .whitespaces),
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests** → 4/4 pass. **Step 5: Commit**

```bash
git add Onda/Books/BookPatternExtractor.swift OndaTests/BookPatternExtractorTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: tier-2 pattern extractor (quoted-title-by-person, reading-list blocks)"
```

---

### Task 5: Verification gate (OpenLibrary + fuzzy matcher)

**Files:**
- Create: `Onda/Books/BookVerifier.swift`
- Test: `OndaTests/BookVerifierTests.swift`

**Interfaces:**
- Produces:
  - `struct VerifiedBook: Equatable, Sendable { let workKey: String; let title: String; let author: String?; let coverURL: URL? }`
  - `struct BookVerifier { typealias Transport = @Sendable (URL) async throws -> Data; var transport: Transport; func verify(_ candidate: BookCandidate) async -> VerifiedBook? }`
  - `static func titleSimilarity(_ a: String, _ b: String) -> Double` (normalized 0–1; internal for tests)
- Threshold: similarity ≥ 0.85; when the candidate has an author, the result's author must share the candidate author's last word (case-insensitive).

- [ ] **Step 1: Write the failing test**

Create `OndaTests/BookVerifierTests.swift`:

```swift
//  BookVerifierTests.swift
import XCTest
@testable import Onda

final class BookVerifierTests: XCTestCase {
    private func olResponse(_ docs: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["docs": docs])
    }

    private func stub(_ data: Data) -> BookVerifier {
        BookVerifier(transport: { _ in data })
    }

    func test_exactMatch_verifies() async {
        let v = stub(olResponse([["key": "/works/OL123W", "title": "Atomic Habits",
                                  "author_name": ["James Clear"], "cover_i": 123]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertEqual(out?.workKey, "/works/OL123W")
        XCTAssertEqual(out?.author, "James Clear")
        XCTAssertEqual(out?.coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/123-M.jpg")
    }

    func test_dissimilarTitle_rejected() async {
        let v = stub(olResponse([["key": "/works/OL9W", "title": "A Completely Different Book",
                                  "author_name": ["James Clear"]]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out, "similarity below threshold must be dropped, never shown")
    }

    func test_authorMismatch_rejected() async {
        let v = stub(olResponse([["key": "/works/OL5W", "title": "Atomic Habits",
                                  "author_name": ["Somebody Else"]]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out)
    }

    func test_transportFailure_returnsNil() async {
        let v = BookVerifier(transport: { _ in throw URLError(.notConnectedToInternet) })
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: nil,
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out, "network failure = unverified = dropped, no crash")
    }

    func test_titleSimilarity_subtitleDropStillMatches() {
        XCTAssertGreaterThanOrEqual(
            BookVerifier.titleSimilarity("deep work",
                                         "Deep Work: Rules for Focused Success"), 0.85)
        XCTAssertLessThan(BookVerifier.titleSimilarity("sapiens", "homo deus"), 0.85)
    }
}
```

- [ ] **Step 2: Run to verify fail** → cannot find `BookVerifier`.

- [ ] **Step 3: Implement**

Create `Onda/Books/BookVerifier.swift`:

```swift
//  BookVerifier.swift
//  The gate that makes best-effort trustworthy: a candidate becomes visible ONLY if it
//  fuzzy-matches a real book in OpenLibrary. No match, network failure, or garbled title →
//  dropped silently (precision over recall, per the design spec).
import Foundation

struct VerifiedBook: Equatable, Sendable {
    let workKey: String
    let title: String
    let author: String?
    let coverURL: URL?
}

struct BookVerifier: Sendable {
    typealias Transport = @Sendable (URL) async throws -> Data
    var transport: Transport = { url in try await URLSession.shared.data(from: url).0 }

    static let similarityThreshold = 0.85

    func verify(_ candidate: BookCandidate) async -> VerifiedBook? {
        guard let url = Self.searchURL(for: candidate) else { return nil }
        guard let data = try? await transport(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return nil }
        for doc in docs.prefix(5) {
            guard let key = doc["key"] as? String, let title = doc["title"] as? String else { continue }
            let authors = (doc["author_name"] as? [String]) ?? []
            if let wanted = candidate.title,
               Self.titleSimilarity(wanted, title) < Self.similarityThreshold { continue }
            if let wantedAuthor = candidate.author {
                let lastWord = wantedAuthor.split(separator: " ").last.map(String.init) ?? wantedAuthor
                guard authors.contains(where: { $0.localizedCaseInsensitiveContains(lastWord) })
                else { continue }
            }
            let cover = (doc["cover_i"] as? Int).flatMap {
                URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg")
            }
            return VerifiedBook(workKey: key, title: title, author: authors.first, coverURL: cover)
        }
        return nil
    }

    /// ISBN/ASIN candidates search by identifier; text candidates by title (+author).
    static func searchURL(for candidate: BookCandidate) -> URL? {
        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "limit", value: "5")]
        if let isbn = candidate.isbnOrASIN, isbn.count == 10 || isbn.count == 13 {
            items.append(URLQueryItem(name: "isbn", value: isbn))
        } else if let title = candidate.title, !title.isEmpty {
            items.append(URLQueryItem(name: "title", value: title))
            if let author = candidate.author { items.append(URLQueryItem(name: "author", value: author)) }
        } else {
            return nil   // ASIN-only (non-ISBN) with no title can't be verified — drop
        }
        comps.queryItems = items
        return comps.url
    }

    /// Token-overlap similarity on normalized words, tolerant of dropped subtitles:
    /// the SHORTER title's tokens must nearly all appear in the longer one.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        let hit = short.filter(long.contains).count
        return Double(hit) / Double(short.count)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 || $0 == "a" })
    }
}
```

- [ ] **Step 4: Run tests** → 5/5 pass. **Step 5: Commit**

```bash
git add Onda/Books/BookVerifier.swift OndaTests/BookVerifierTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: OpenLibrary verification gate with fuzzy title matcher"
```

---

### Task 6: LLM extractor protocol + Foundation Models implementation (tier 3)

**Files:**
- Create: `Onda/Books/BookExtracting.swift`
- Test: `OndaTests/BookExtractingContractTests.swift`

**Interfaces:**
- Produces:
  - `struct LLMBookCandidate: Equatable, Sendable { let title: String; let author: String?; let nearbyQuote: String }`
  - `protocol BookExtracting: Sendable { func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate] }`
  - `FoundationModelsBookExtractor` (iOS 26 + `#if canImport(FoundationModels)`, `isAvailable` gate) — mirrors `FoundationModelsChapterGenerator` exactly.

- [ ] **Step 1: Write the failing contract test** (the FM path is hardware-gated and untestable in CI — the fake asserts the protocol contract, same accepted gap as chapters):

Create `OndaTests/BookExtractingContractTests.swift`:

```swift
//  BookExtractingContractTests.swift
import XCTest
@testable import Onda

private struct FakeExtractor: BookExtracting {
    var result: [LLMBookCandidate]
    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate] { result }
}

final class BookExtractingContractTests: XCTestCase {
    func test_fakeConformsAndRoundTrips() async throws {
        let fake = FakeExtractor(result: [LLMBookCandidate(
            title: "Atomic Habits", author: "James Clear",
            nearbyQuote: "tiny changes remarkable results")])
        let out = try await fake.bookCandidates(transcriptChunks: ["chunk"])
        XCTAssertEqual(out.first?.title, "Atomic Habits")
        XCTAssertEqual(out.first?.nearbyQuote, "tiny changes remarkable results")
    }
}
```

- [ ] **Step 2: Run to verify fail** → cannot find `BookExtracting`.

- [ ] **Step 3: Implement**

Create `Onda/Books/BookExtracting.swift`:

```swift
//  BookExtracting.swift
//  Tier 3: on-device LLM extraction of conversational book mentions. Same framework,
//  availability gate, and protocol-behind-a-fake pattern as FoundationModelsChapterGenerator.
import Foundation

struct LLMBookCandidate: Equatable, Sendable {
    let title: String
    let author: String?
    let nearbyQuote: String   // short verbatim phrase near the mention — matched back to a cue
}

enum BookExtractionError: Error { case unavailable }

protocol BookExtracting: Sendable {
    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate]
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
final class FoundationModelsBookExtractor: BookExtracting {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct ExtractedBooks {
        @Guide(description: "Every real, published book explicitly mentioned by title in the text. Empty if none.")
        let books: [ExtractedBook]
    }

    @Generable
    struct ExtractedBook {
        @Guide(description: "The book's title exactly as commonly published")
        let title: String
        @Guide(description: "The author's name if stated or well known, otherwise empty")
        let author: String
        @Guide(description: "A short verbatim phrase (5-12 words) copied from the text near the mention")
        let nearbyQuote: String
    }

    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate] {
        guard Self.isAvailable else { throw BookExtractionError.unavailable }
        var out: [LLMBookCandidate] = []
        for chunk in transcriptChunks {
            let session = LanguageModelSession()
            let prompt = """
            List every real, published book that is explicitly mentioned by title in this \
            podcast transcript excerpt. Do not guess or infer books that are only alluded to. \
            If none are mentioned, return an empty list.

            Excerpt:
            \(chunk.prefix(12_000))
            """
            let result = try await session.respond(to: prompt, generating: ExtractedBooks.self)
            out.append(contentsOf: result.content.books.map {
                LLMBookCandidate(title: $0.title,
                                 author: $0.author.isEmpty ? nil : $0.author,
                                 nearbyQuote: $0.nearbyQuote)
            })
        }
        return out
    }
}
#endif
```

- [ ] **Step 4: `xcodegen generate`, run contract test + build** → pass, `** BUILD SUCCEEDED **`. **Step 5: Commit**

```bash
git add Onda/Books/BookExtracting.swift OndaTests/BookExtractingContractTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: BookExtracting protocol + Foundation Models book extractor (AI-gated)"
```

---

### Task 7: BookMentionService — the single-episode funnel

**Files:**
- Create: `Onda/Books/BookMentionService.swift`
- Test: `OndaTests/BookMentionServiceTests.swift`

**Interfaces:**
- Produces (`@MainActor @Observable final class BookMentionService`):
  - `init(modelContext: ModelContext, verifier: BookVerifier, llm: BookExtracting?, isPersonName: ((String) -> Bool)? = nil)` — `llm` nil below iOS 26/AI; `isPersonName` nil → NLTagger-backed default.
  - `func findBooks(for episode: Episode) async` — the ONLY entry point; takes exactly one episode. No batch API may be added.
  - `var inFlightGuid: String?` (progress), `var lastFailure: String?`.
- Consumes: `BookLinkParser`, `BookPatternExtractor`, `BookVerifier`, `BookExtracting`, `Episode.noteLinks`, `Episode.bookMentions`, transcript cues.

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/BookMentionServiceTests.swift`:

```swift
//  BookMentionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubLLM: BookExtracting {
    var result: [LLMBookCandidate] = []
    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate] { result }
}

@MainActor
final class BookMentionServiceTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makeEpisode(_ ctx: ModelContext, isPrivate: Bool = false,
                             noteLinks: [URL] = [], cues: [(String, Double)] = []) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1,
                          isPrivateFeed: isPrivate)
        let ep = Episode(guid: "g", title: "E", publishDate: .now, duration: 1000,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "",
                         noteLinks: noteLinks)
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep)
        if !cues.isEmpty {
            let tr = Transcript(source: "ondevice", language: "en"); tr.episode = ep; ep.transcript = tr
            ctx.insert(tr)
            for (text, start) in cues {
                let cue = TranscriptCue(startTime: start, endTime: start + 5, text: text, speaker: nil)
                cue.transcript = tr; tr.cues.append(cue); ctx.insert(cue)
            }
        }
        return ep
    }

    private func verifierReturning(_ book: VerifiedBook?) -> BookVerifier {
        BookVerifier(transport: { _ in
            guard let book else { throw URLError(.notConnectedToInternet) }
            let doc: [String: Any] = ["key": book.workKey, "title": book.title,
                                      "author_name": book.author.map { [$0] } ?? []]
            return try JSONSerialization.data(withJSONObject: ["docs": [doc]])
        })
    }

    func test_linkCandidate_verifies_andPersists() async throws {
        let ctx = try ctx()
        let ep = makeEpisode(ctx, noteLinks: [URL(string: "https://amazon.com/dp/0735211299")!])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: "James Clear", coverURL: nil)),
            llm: nil, isPersonName: { _ in false })
        await svc.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.count, 1)
        XCTAssertEqual(ep.bookMentions.first?.title, "Atomic Habits")
        XCTAssertEqual(ep.bookMentions.first?.sourceTier, "link")
    }

    func test_llmCandidate_recoversTimestampFromQuote() async throws {
        let ctx = try ctx()
        let ep = makeEpisode(ctx, cues: [("we talked about tiny changes remarkable results", 640)])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: nil, coverURL: nil)),
            llm: StubLLM(result: [LLMBookCandidate(title: "Atomic Habits", author: nil,
                                                   nearbyQuote: "tiny changes remarkable results")]),
            isPersonName: { _ in false })
        await svc.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.first?.timestamp, 640)
        XCTAssertEqual(ep.bookMentions.first?.sourceTier, "transcript")
    }

    func test_privateFeed_isExcludedEntirely() async throws {
        let ctx = try ctx()
        let ep = makeEpisode(ctx, isPrivate: true,
                             noteLinks: [URL(string: "https://amazon.com/dp/0735211299")!])
        let svc = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "X",
                                                     author: nil, coverURL: nil)),
            llm: nil, isPersonName: { _ in false })
        await svc.findBooks(for: ep)
        XCTAssertTrue(ep.bookMentions.isEmpty, "private feeds never reach the network")
        XCTAssertNotNil(svc.lastFailure)
    }

    func test_unverifiedCandidates_neverPersist_andRerunReplaces() async throws {
        let ctx = try ctx()
        let ep = makeEpisode(ctx, noteLinks: [URL(string: "https://amazon.com/dp/0735211299")!])
        let failing = BookMentionService(modelContext: ctx, verifier: verifierReturning(nil),
                                         llm: nil, isPersonName: { _ in false })
        await failing.findBooks(for: ep)
        XCTAssertTrue(ep.bookMentions.isEmpty, "verification failure -> nothing persisted")

        let working = BookMentionService(
            modelContext: ctx,
            verifier: verifierReturning(VerifiedBook(workKey: "/works/OL1W", title: "Atomic Habits",
                                                     author: nil, coverURL: nil)),
            llm: nil, isPersonName: { _ in false })
        await working.findBooks(for: ep)
        await working.findBooks(for: ep)
        XCTAssertEqual(ep.bookMentions.count, 1, "re-run replaces, never accumulates duplicates")
    }
}
```

- [ ] **Step 2: Run to verify fail** → cannot find `BookMentionService`.

- [ ] **Step 3: Implement**

Create `Onda/Books/BookMentionService.swift`:

```swift
//  BookMentionService.swift
//  The Books Mentioned funnel for ONE episode: link + pattern + LLM candidates → the
//  OpenLibrary verification gate → persisted BookMention rows. Strictly single-episode and
//  user-initiated by design (see the spec): there is no batch entry point, and none may be
//  added — the feature answers "what was that book in THIS episode?", nothing broader.
import Foundation
import NaturalLanguage
import SwiftData

@MainActor
@Observable
final class BookMentionService {
    private let modelContext: ModelContext
    private let verifier: BookVerifier
    private let llm: BookExtracting?
    private let isPersonName: (String) -> Bool

    /// guid of the episode currently being processed (drives the sheet's progress state).
    private(set) var inFlightGuid: String?
    var lastFailure: String?

    init(modelContext: ModelContext, verifier: BookVerifier = BookVerifier(),
         llm: BookExtracting? = nil, isPersonName: ((String) -> Bool)? = nil) {
        self.modelContext = modelContext
        self.verifier = verifier
        self.llm = llm
        self.isPersonName = isPersonName ?? Self.nlPersonCheck
    }

    /// Runs the full funnel for exactly one episode; re-running replaces its results.
    func findBooks(for episode: Episode) async {
        guard episode.podcast?.isPrivateFeed != true else {
            lastFailure = "Books can't be looked up for private shows — their content never leaves this device."
            return
        }
        guard inFlightGuid == nil else { return }
        inFlightGuid = episode.guid
        lastFailure = nil
        defer { inFlightGuid = nil }

        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { (text: $0.text, start: $0.startTime) }

        var candidates = BookLinkParser.candidates(from: episode.noteLinks)
        let patterns = BookPatternExtractor(isPersonName: isPersonName)
        candidates += patterns.candidates(fromNotes: episode.notes)
        candidates += patterns.candidates(fromCues: cues)
        candidates += await llmCandidates(cues: cues)

        var verified: [(VerifiedBook, BookCandidate)] = []
        for candidate in candidates {
            if let book = await verifier.verify(candidate) { verified.append((book, candidate)) }
        }

        guard !verified.isEmpty else {
            if candidates.isEmpty {
                lastFailure = "No book mentions found in this episode's notes or transcript."
            } else {
                lastFailure = "Couldn't verify any mentions — check your connection and try again."
            }
            return
        }

        // Replace-on-rerun; dedupe by work key, preferring entries that carry a timestamp.
        for old in episode.bookMentions { modelContext.delete(old) }
        episode.bookMentions.removeAll()
        var byKey: [String: (VerifiedBook, BookCandidate)] = [:]
        for (book, candidate) in verified {
            if let existing = byKey[book.workKey], existing.1.timestamp != nil { continue }
            byKey[book.workKey] = (book, candidate)
        }
        for (book, candidate) in byKey.values {
            let mention = BookMention(workKey: book.workKey, title: book.title, author: book.author,
                                      coverURL: book.coverURL,
                                      sourceTier: candidate.sourceTier,
                                      timestamp: candidate.timestamp)
            mention.episode = episode
            episode.bookMentions.append(mention)
            modelContext.insert(mention)
        }
        try? modelContext.save()
    }

    // LLM tier: chapter-sized chunks in, candidates with quote-recovered timestamps out.
    private func llmCandidates(cues: [(text: String, start: TimeInterval)]) async -> [BookCandidate] {
        guard let llm, !cues.isEmpty else { return [] }
        let fullText = cues.map(\.text).joined(separator: " ")
        let chunks = stride(from: 0, to: fullText.count, by: 10_000).map {
            String(fullText.dropFirst($0).prefix(10_000))
        }
        guard let found = try? await llm.bookCandidates(transcriptChunks: chunks) else { return [] }
        return found.map { c in
            BookCandidate(title: c.title, author: c.author, isbnOrASIN: nil,
                          timestamp: Self.timestamp(forQuote: c.nearbyQuote, in: cues),
                          sourceTier: "transcript")
        }
    }

    /// Recovers a cue timestamp by substring-matching the LLM's verbatim quote.
    static func timestamp(forQuote quote: String,
                          in cues: [(text: String, start: TimeInterval)]) -> TimeInterval? {
        let needle = quote.lowercased().trimmingCharacters(in: .whitespaces)
        guard needle.count >= 8 else { return nil }
        return cues.first { $0.text.lowercased().contains(needle) }?.start
    }

    /// Production person check (tests inject a deterministic closure instead — NL models
    /// are flaky in simulators, docs/BUGS.md #2).
    private static func nlPersonCheck(_ name: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = name
        var isPerson = false
        tagger.enumerateTags(in: name.startIndex..<name.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .personalName { isPerson = true }
            return true
        }
        return isPerson
    }
}
```

- [ ] **Step 4: `xcodegen generate`, run BookMentionServiceTests + full OndaTests** → all pass. **Step 5: Commit**

```bash
git add Onda/Books/BookMentionService.swift OndaTests/BookMentionServiceTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: BookMentionService - single-episode funnel with verification gate"
```

---

### Task 8: BooksSheet UI + player entry point + wiring

**Files:**
- Create: `Onda/Books/BooksSheet.swift`
- Modify: `Onda/Player/NowPlayingView.swift` (header icon + sheet), `Onda/Player/TranscriptView.swift` (optional initial search), `Onda/OndaApp.swift` (construct + inject service)

**Interfaces:**
- Consumes: `BookMentionService.findBooks(for:)`, `inFlightGuid`, `lastFailure`; `playback.jumpFromTranscript(episode:to:)`; `BrutalEmptyState`; `ArtworkView(url:seed:)`.
- Produces: `BooksSheet(episode: Episode)`; `TranscriptView` gains `var initialSearch: String? = nil`.

- [ ] **Step 1: TranscriptView prefill hook**

In `Onda/Player/TranscriptView.swift`: add `var initialSearch: String? = nil` next to `let episode`, and where the view's `.task { await load() }` runs, extend it (the in-panel search state is `query` + `searching`):

```swift
        .task {
            await load()
            if let initialSearch, !initialSearch.isEmpty {
                query = initialSearch
                searching = true
            }
        }
```

(Anchor on the existing `.task { await load() }`; keep `load()` first.)

- [ ] **Step 2: Create the sheet**

Create `Onda/Books/BooksSheet.swift`:

```swift
//  BooksSheet.swift
//  "What was that book in THIS episode?" — presented from the player for the current episode.
//  Strictly per-episode: the Find action runs the funnel for this one episode only.
import SwiftUI

struct BooksSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(BookMentionService.self) private var books
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    @State private var readingTranscriptSearch: String?

    private var isPrivate: Bool { episode.podcast?.isPrivateFeed == true }
    private var running: Bool { books.inFlightGuid == episode.guid }
    private var mentions: [BookMention] {
        episode.bookMentions.sorted { ($0.timestamp ?? .infinity) < ($1.timestamp ?? .infinity) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isPrivate {
                        BrutalEmptyState("Not available for private shows",
                                         detail: "Verifying books needs a catalog lookup, and private shows' content never leaves this device.")
                    } else if running {
                        HStack(spacing: 8) {
                            ProgressView().tint(theme.color(.accent))
                            Text("Finding books\u{2026}").scaledFont(13)
                                .foregroundStyle(theme.color(.textTertiary))
                        }.frame(maxWidth: .infinity).padding(.top, 40)
                    } else if mentions.isEmpty {
                        BrutalEmptyState(books.lastFailure == nil
                                         ? "Find the books mentioned in this episode"
                                         : "No books found",
                                         detail: books.lastFailure
                                         ?? "Scans this episode's show notes and transcript; only books verified against a real catalog are shown.")
                        findButton
                    } else {
                        ForEach(mentions) { bookRow($0) }
                        findButton   // re-run replaces results
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle("Books Mentioned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $readingTranscriptSearch) { search in
                TranscriptView(episode: episode, initialSearch: search)
            }
        }
    }

    private var findButton: some View {
        Button {
            Task { await books.findBooks(for: episode) }
        } label: {
            Text(mentions.isEmpty ? "Find Books" : "Find Again")
                .scaledFont(14, weight: .bold).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(theme.color(.accentStrong)).brutalBorder(width: 2.5)
        }
        .buttonStyle(.plain)
        .disabled(isPrivate || running)
        .accessibilityLabel("Find books mentioned in this episode")
    }

    private func bookRow(_ book: BookMention) -> some View {
        Button {
            if let t = book.timestamp {
                dismiss()
                playback.jumpFromTranscript(episode: episode, to: t)
            } else {
                readingTranscriptSearch = book.title
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: book.coverURL, seed: book.title)
                    .frame(width: 44, height: 60).brutalBorder(width: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).scaledFont(15, weight: .bold)
                        .foregroundStyle(theme.color(.text)).lineLimit(2)
                    if let author = book.author {
                        Text(author).scaledFont(12.5)
                            .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                    }
                    if let t = book.timestamp {
                        Text("Mentioned at \(timeStr(t))").scaledFont(11.5, weight: .semibold)
                            .foregroundStyle(theme.color(.accent))
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: book.timestamp != nil ? "play.circle" : "text.magnifyingglass")
                    .scaledFont(16).foregroundStyle(theme.color(.textTertiary))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.timestamp != nil
                            ? "\(book.title): jump to where it was mentioned"
                            : "\(book.title): search the transcript for it")
        .contextMenu {
            Button { UIPasteboard.general.string = [book.title, book.author].compactMap { $0 }.joined(separator: " — ") } label: {
                Label("Copy Title & Author", systemImage: "doc.on.doc")
            }
            if let url = URL(string: "https://openlibrary.org\(book.workKey)") {
                Link(destination: url) { Label("Open in OpenLibrary", systemImage: "safari") }
            }
        }
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// .sheet(item:) needs Identifiable — a search string is its own identity here.
extension String: @retroactive Identifiable {
    public var id: String { self }
}
```

**Note:** if the `String: Identifiable` retroactive conformance collides or offends review, replace with a small `struct TranscriptSearchTarget: Identifiable { let id = UUID(); let query: String }` — do NOT fight the compiler over it.

- [ ] **Step 3: Player entry point**

In `Onda/Player/NowPlayingView.swift`:
- Add state: `@State private var showBooks = false` (next to `showQueue`).
- In `header`'s `HStack`, insert a book icon between the scissors and `SleepTimerMenu()`:

```swift
            Button { showBooks = true } label: { headerIcon("book") }
                .disabled(ep == nil)
                .accessibilityLabel("Books mentioned in this episode")
                .accessibilityIdentifier("books-button")
```

- Add alongside the other sheets:

```swift
        .sheet(isPresented: $showBooks) {
            if let ep { BooksSheet(episode: ep).presentationDetents([.medium, .large]) }
        }
```

The header already holds 6 44pt items plus the sleep menu; if 7 no longer fit on the 375pt-wide iPhone 13 mini (build + eyeball via the probe screenshot in Task 9), reduce `headerIcon`'s frame width from 44 to 40 for ALL header icons (height stays 44) rather than dropping the button.

- [ ] **Step 4: Wiring**

In `Onda/OndaApp.swift`:
- Add `@State private var books: BookMentionService`.
- In `init()`, after the recommendations construction:

```swift
            let llmExtractor: BookExtracting? = {
                if #available(iOS 26, *), FoundationModelsBookExtractor.isAvailable {
                    return FoundationModelsBookExtractor()
                }
                return nil
            }()
            _books = State(initialValue: BookMentionService(modelContext: c.mainContext,
                                                            llm: llmExtractor))
```

- Add `.environment(books)` with the other `.environment(...)` modifiers.
- If the init's function-body-length lint warning (grandfathered at 51) trips harder, move the extractor construction into a `private static func makeBookExtractor() -> BookExtracting?` like `makeChapterGenerator`.

- [ ] **Step 5: Build + lint + full unit suite** → all green. **Step 6: Commit**

```bash
git add Onda/Books/BooksSheet.swift Onda/Player/NowPlayingView.swift Onda/Player/TranscriptView.swift Onda/OndaApp.swift Onda.xcodeproj/project.pbxproj
git commit -m "feat: Books Mentioned sheet, launched from the player header"
```

---

### Task 9: Verification sweep

**Files:** none (verification only).

- [ ] **Step 1:** Full unit suite (`-only-testing:OndaTests`) → `** TEST SUCCEEDED **`.
- [ ] **Step 2:** UI probes on a fresh dedicated simulator (create/boot/delete an `iPhone-17` device per the `onda:verify` skill): `MiniPlayerProbeUITests`, `LibraryFreezeProbeUITests`, `EpisodeSearchUITests` → all pass. Additionally, extend `MiniPlayerProbeUITests` OR add a small probe asserting the player header's `books-button` exists and opens a sheet titled "Books Mentioned" (seeded episode: tap play → mini-player → open player → tap books icon → assert `staticTexts["Books Mentioned"]` exists → assert the "Find books" CTA exists). The funnel itself needs network + a real feed, so the probe stops at the sheet's empty state.
- [ ] **Step 3:** Full lint minus grandfathered warnings → clean.
- [ ] **Step 4:** Report per-task status. Do NOT push or deploy — the operator does both.

---

## Self-Review Notes

- **Spec coverage:** funnel tiers 1–3 → Tasks 3, 4, 6; verification gate → Task 5; parser prerequisite → Task 1; data model → Task 2; single-episode service + privacy + dedupe/replace → Task 7; player entry + sheet + timestamp jump + in-episode search fallback → Task 8; degradation ladder is emergent (llm nil below iOS 26; verifier failures drop candidates; private-feed guard in service AND sheet).
- **Interface consistency:** `BookCandidate` field order matches across Tasks 3–7; `VerifiedBook`/`BookVerifier.verify` used identically in Tasks 5 and 7; `LLMBookCandidate.nearbyQuote` produced in Task 6, consumed by `timestamp(forQuote:in:)` in Task 7; `TranscriptView.initialSearch` produced and consumed in Task 8.
- **No open-ended surface:** every entry point takes one `Episode`; the sheet is reachable only from the player for the current episode.
