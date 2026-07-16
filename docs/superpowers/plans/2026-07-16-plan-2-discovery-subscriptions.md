# Onda Plan 2: Discovery & Subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user search Apple's podcast directory, browse trending-by-category, subscribe to shows, see their subscriptions in the Library grid, and drill into a per-show Episode List — with episode data parsed client-side from each show's RSS feed.

**Architecture:** `ITunesSearchClient` (URLSession + Codable) provides discovery; `RSSFeedParser` (XMLParser) turns a feed into `ParsedFeed`/`ParsedEpisode`/`ParsedChapter` value types; `SubscriptionService` (`@Observable`) upserts those into SwiftData. Views read subscriptions via `@Query` and call the services. Networking types are pure value types decoupled from SwiftData so they're testable without a container.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, URLSession async/await, XMLParser, XCTest.

## Global Constraints

- Deployment target iOS 17.0; SwiftUI + SwiftData only (see Plan 1 Global Constraints — they apply here verbatim).
- No third-party dependencies. Networking uses `URLSession`; parsing uses Foundation `XMLParser` and `JSONDecoder`.
- No API keys. iTunes Search endpoints only: `https://itunes.apple.com/search`, `https://itunes.apple.com/lookup`, `https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/25/podcasts.json`.
- All network I/O is `async` and injected behind a protocol so tests never hit the network.
- Parser must be tolerant: missing/malformed fields degrade gracefully (skip the field/episode), never throw for one bad item.
- Visual language from Plan 1 (`brutalBorder`, `hardShadow`, `BrutalCard`, `brutalHeader`, `AppTheme.color`).

**Depends on:** Plan 1 (models, theme, shell) complete.

---

## File Structure

```
Onda/
  Networking/
    ITunesSearchClient.swift   — search / lookup / topCharts; PodcastDTO
    RSSFeedParser.swift        — XMLParser delegate → ParsedFeed
    FeedFetching.swift         — protocols (Searching, FeedFetching) + URLSession impls
  Services/
    SubscriptionService.swift  — @Observable; subscribe / unsubscribe / refreshEpisodes
  Shell/
    LibraryView.swift          — MODIFY: real subscription grid
    DiscoverView.swift         — MODIFY: search + categories + trending
  Library/
    ShowCard.swift             — grid cell (art placeholder + title)
    EpisodeListView.swift      — per-show episode list screen
    EpisodeRow.swift           — one episode row
  Discover/
    TrendingRow.swift          — trending show row with Follow button
    ArtworkView.swift          — themed gradient-art placeholder used everywhere
OndaTests/
  ITunesSearchClientTests.swift
  RSSFeedParserTests.swift
  SubscriptionServiceTests.swift
OndaTests/Fixtures/
  itunes_search.json
  feed_basic.xml
  feed_messy.xml
```

---

### Task 1: iTunes Search client + DTOs

**Files:**
- Create: `Onda/Networking/ITunesSearchClient.swift`, `Onda/Networking/FeedFetching.swift`
- Create: `OndaTests/Fixtures/itunes_search.json`, `OndaTests/ITunesSearchClientTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PodcastDTO: Codable, Equatable { let feedUrl: URL?; let collectionName: String; let artistName: String; let artworkUrl600: URL?; let primaryGenreName: String?; let collectionId: Int? }`
  - `protocol Searching { func search(term: String) async throws -> [PodcastDTO]; func lookup(ids: [Int]) async throws -> [PodcastDTO]; func topChartIds(limit: Int) async throws -> [Int] }`
  - `struct ITunesSearchClient: Searching` (init takes `URLSession = .shared` and a `data(from:)` closure for test injection)
  - `func decodeSearch(_ data: Data) throws -> [PodcastDTO]` (pure, tested directly)

- [ ] **Step 1: Add the fixture**

Create `OndaTests/Fixtures/itunes_search.json`:

```json
{
  "resultCount": 2,
  "results": [
    { "collectionId": 1, "collectionName": "The Signal", "artistName": "Ex Media",
      "feedUrl": "https://ex.com/signal.xml", "artworkUrl600": "https://ex.com/a600.jpg",
      "primaryGenreName": "Technology" },
    { "collectionId": 2, "collectionName": "No Feed Show", "artistName": "Nobody",
      "artworkUrl600": "https://ex.com/b600.jpg", "primaryGenreName": "Comedy" }
  ]
}
```

- [ ] **Step 2: Write the failing decode test**

Create `OndaTests/ITunesSearchClientTests.swift`:

```swift
//  ITunesSearchClientTests.swift
import XCTest
@testable import Onda

final class ITunesSearchClientTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)!
        return try Data(contentsOf: url)
    }

    func test_decodeSearch_parsesResults_andTolueratesMissingFeedUrl() throws {
        let data = try fixture("itunes_search", "json")
        let client = ITunesSearchClient()
        let dtos = try client.decodeSearch(data)
        XCTAssertEqual(dtos.count, 2)
        XCTAssertEqual(dtos[0].collectionName, "The Signal")
        XCTAssertEqual(dtos[0].feedUrl, URL(string: "https://ex.com/signal.xml"))
        XCTAssertNil(dtos[1].feedUrl)  // missing feedUrl decodes as nil, not an error
    }

    func test_search_usesInjectedTransport_andEncodesTerm() async throws {
        let data = try fixture("itunes_search", "json")
        var requestedURL: URL?
        let client = ITunesSearchClient(transport: { url in requestedURL = url; return data })
        let dtos = try await client.search(term: "slow burn")
        XCTAssertEqual(dtos.count, 2)
        XCTAssertTrue(requestedURL?.absoluteString.contains("term=slow%20burn") ?? false)
        XCTAssertTrue(requestedURL?.absoluteString.contains("media=podcast") ?? false)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ITunesSearchClientTests`
Expected: FAIL — `cannot find 'ITunesSearchClient' in scope`.

> If the fixture isn't found at runtime, ensure `OndaTests/Fixtures/**` is in the `OndaTests` target's resources. In `project.yml` add under the `OndaTests` target: `sources: [OndaTests]` already globs it; if not copied, add `resources: [OndaTests/Fixtures]` and re-run `xcodegen generate`.

- [ ] **Step 4: Write the protocol + client**

Create `Onda/Networking/FeedFetching.swift`:

```swift
//  FeedFetching.swift
import Foundation

protocol Searching {
    func search(term: String) async throws -> [PodcastDTO]
    func lookup(ids: [Int]) async throws -> [PodcastDTO]
    func topChartIds(limit: Int) async throws -> [Int]
}

protocol FeedFetching {
    func fetchFeed(_ url: URL) async throws -> ParsedFeed
}
```

Create `Onda/Networking/ITunesSearchClient.swift`:

```swift
//  ITunesSearchClient.swift
import Foundation

struct PodcastDTO: Codable, Equatable {
    let collectionId: Int?
    let collectionName: String
    let artistName: String
    let feedUrl: URL?
    let artworkUrl600: URL?
    let primaryGenreName: String?
}

struct ITunesSearchClient: Searching {
    typealias Transport = (URL) async throws -> Data
    private let transport: Transport

    init(transport: @escaping Transport = { url in
        try await URLSession.shared.data(from: url).0
    }) {
        self.transport = transport
    }

    // Pure, unit-tested directly.
    func decodeSearch(_ data: Data) throws -> [PodcastDTO] {
        struct Envelope: Codable { let results: [PodcastDTO] }
        return try JSONDecoder().decode(Envelope.self, from: data).results
    }

    func search(term: String) async throws -> [PodcastDTO] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "media", value: "podcast"),
                        .init(name: "entity", value: "podcast"),
                        .init(name: "limit", value: "50"),
                        .init(name: "term", value: term)]
        return try decodeSearch(try await transport(c.url!))
    }

    func lookup(ids: [Int]) async throws -> [PodcastDTO] {
        guard !ids.isEmpty else { return [] }
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [.init(name: "id", value: ids.map(String.init).joined(separator: ",")),
                        .init(name: "entity", value: "podcast")]
        return try decodeSearch(try await transport(c.url!))
    }

    func topChartIds(limit: Int) async throws -> [Int] {
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/\(limit)/podcasts.json")!
        struct Charts: Codable {
            struct Feed: Codable { struct Result: Codable { let id: String }; let results: [Result] }
            let feed: Feed
        }
        let data = try await transport(url)
        return try JSONDecoder().decode(Charts.self, from: data).feed.results.compactMap { Int($0.id) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ITunesSearchClientTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Onda/Networking OndaTests/ITunesSearchClientTests.swift OndaTests/Fixtures/itunes_search.json project.yml
git commit -m "feat: ITunesSearchClient (search/lookup/topCharts) with injectable transport"
```

---

### Task 2: RSS feed parser

**Files:**
- Create: `Onda/Networking/RSSFeedParser.swift`
- Create: `OndaTests/Fixtures/feed_basic.xml`, `OndaTests/Fixtures/feed_messy.xml`, `OndaTests/RSSFeedParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ParsedFeed { let title: String; let author: String; let artworkURL: URL?; let category: String; let episodes: [ParsedEpisode] }`
  - `struct ParsedEpisode { let guid: String; let title: String; let publishDate: Date; let duration: TimeInterval; let audioURL: URL; let notes: String; let chaptersURL: URL? }`
  - `struct RSSFeedParser { func parse(_ data: Data) -> ParsedFeed? }` (returns nil only if there's no channel at all; individual bad items are skipped)
  - `static func parseDuration(_ raw: String) -> TimeInterval` (handles `"3600"`, `"1:02:03"`, `"02:03"`)

- [ ] **Step 1: Add fixtures**

Create `OndaTests/Fixtures/feed_basic.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:podcast="https://podcastindex.org/namespace/1.0">
  <channel>
    <title>The Signal</title>
    <itunes:author>Ex Media</itunes:author>
    <itunes:category text="Technology"/>
    <itunes:image href="https://ex.com/art.jpg"/>
    <item>
      <title>Ep 142: The Slow Death of the Homepage</title>
      <guid>sig-142</guid>
      <pubDate>Tue, 15 Jul 2026 09:00:00 +0000</pubDate>
      <itunes:duration>2292</itunes:duration>
      <enclosure url="https://ex.com/142.mp3" type="audio/mpeg" length="1000"/>
      <description>Homepages used to be the front door.</description>
      <podcast:chapters url="https://ex.com/142-chapters.json" type="application/json+chapters"/>
    </item>
  </channel>
</rss>
```

Create `OndaTests/Fixtures/feed_messy.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Messy Show</title>
    <item>
      <title>Good Episode</title>
      <guid>good-1</guid>
      <pubDate>Mon, 14 Jul 2026 09:00:00 +0000</pubDate>
      <itunes:duration>1:02:03</itunes:duration>
      <enclosure url="https://ex.com/good.mp3" type="audio/mpeg"/>
      <description>Fine.</description>
    </item>
    <item>
      <title>No Enclosure Episode</title>
      <guid>bad-1</guid>
      <pubDate>garbage-date</pubDate>
      <description>Should be skipped (no audio url).</description>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: Write the failing parser tests**

Create `OndaTests/RSSFeedParserTests.swift`:

```swift
//  RSSFeedParserTests.swift
import XCTest
@testable import Onda

final class RSSFeedParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "xml")!
        return try Data(contentsOf: url)
    }

    func test_parseBasic_extractsChannelAndEpisode() throws {
        let feed = RSSFeedParser().parse(try fixture("feed_basic"))
        let f = try XCTUnwrap(feed)
        XCTAssertEqual(f.title, "The Signal")
        XCTAssertEqual(f.author, "Ex Media")
        XCTAssertEqual(f.category, "Technology")
        XCTAssertEqual(f.artworkURL, URL(string: "https://ex.com/art.jpg"))
        XCTAssertEqual(f.episodes.count, 1)
        let ep = f.episodes[0]
        XCTAssertEqual(ep.guid, "sig-142")
        XCTAssertEqual(ep.duration, 2292)
        XCTAssertEqual(ep.audioURL, URL(string: "https://ex.com/142.mp3"))
        XCTAssertEqual(ep.chaptersURL, URL(string: "https://ex.com/142-chapters.json"))
    }

    func test_parseMessy_skipsItemWithoutAudio_andParsesHMSDuration() throws {
        let feed = RSSFeedParser().parse(try fixture("feed_messy"))
        let f = try XCTUnwrap(feed)
        XCTAssertEqual(f.episodes.count, 1, "episode without an enclosure URL is skipped")
        XCTAssertEqual(f.episodes[0].guid, "good-1")
        XCTAssertEqual(f.episodes[0].duration, 3723) // 1:02:03
    }

    func test_parseDuration_handlesFormats() {
        XCTAssertEqual(RSSFeedParser.parseDuration("3600"), 3600)
        XCTAssertEqual(RSSFeedParser.parseDuration("02:03"), 123)
        XCTAssertEqual(RSSFeedParser.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(RSSFeedParser.parseDuration("garbage"), 0)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/RSSFeedParserTests`
Expected: FAIL — `cannot find 'RSSFeedParser' in scope`.

- [ ] **Step 4: Write the parser**

Create `Onda/Networking/RSSFeedParser.swift`:

```swift
//  RSSFeedParser.swift
import Foundation

struct ParsedEpisode {
    let guid: String
    let title: String
    let publishDate: Date
    let duration: TimeInterval
    let audioURL: URL
    let notes: String
    let chaptersURL: URL?
}

struct ParsedFeed {
    let title: String
    let author: String
    let artworkURL: URL?
    let category: String
    let episodes: [ParsedEpisode]
}

struct RSSFeedParser {
    func parse(_ data: Data) -> ParsedFeed? {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), delegate.sawChannel else { return nil }
        return delegate.buildFeed()
    }

    static func parseDuration(_ raw: String) -> TimeInterval {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if !t.contains(":") { return TimeInterval(t) ?? 0 }
        let parts = t.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

private final class FeedDelegate: NSObject, XMLParserDelegate {
    var sawChannel = false
    private var channelTitle = "", channelAuthor = "", channelCategory = ""
    private var channelArtwork: URL?

    private struct Item {
        var guid = "", title = "", notes = ""
        var pubDate: Date = .distantPast
        var duration: TimeInterval = 0
        var audioURL: URL?
        var chaptersURL: URL?
    }
    private var items: [Item] = []
    private var current: Item?
    private var inItem = false
    private var text = ""

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes attrs: [String: String]) {
        text = ""
        switch el {
        case "channel": sawChannel = true
        case "item": inItem = true; current = Item()
        case "itunes:image": if !inItem, let h = attrs["href"] { channelArtwork = URL(string: h) }
        case "itunes:category": if !inItem, let t = attrs["text"], channelCategory.isEmpty { channelCategory = t }
        case "enclosure": if inItem, let u = attrs["url"] { current?.audioURL = URL(string: u) }
        case "podcast:chapters": if inItem, let u = attrs["url"] { current?.chaptersURL = URL(string: u) }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch el {
            case "title": current?.title = value
            case "guid": current?.guid = value
            case "description", "itunes:summary":
                if current?.notes.isEmpty ?? true { current?.notes = stripHTML(value) }
            case "pubDate": current?.pubDate = FeedDelegate.rfc822.date(from: value) ?? .distantPast
            case "itunes:duration": current?.duration = RSSFeedParser.parseDuration(value)
            case "item":
                if let c = current { items.append(c) }
                current = nil; inItem = false
            default: break
            }
        } else {
            switch el {
            case "title": if channelTitle.isEmpty { channelTitle = value }
            case "itunes:author": channelAuthor = value
            default: break
            }
        }
        text = ""
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildFeed() -> ParsedFeed {
        let eps: [ParsedEpisode] = items.compactMap { it in
            guard let audio = it.audioURL else { return nil }   // skip items without audio
            let guid = it.guid.isEmpty ? audio.absoluteString : it.guid
            return ParsedEpisode(guid: guid, title: it.title, publishDate: it.pubDate,
                                 duration: it.duration, audioURL: audio, notes: it.notes,
                                 chaptersURL: it.chaptersURL)
        }
        return ParsedFeed(title: channelTitle, author: channelAuthor,
                          artworkURL: channelArtwork, category: channelCategory.isEmpty ? "Podcast" : channelCategory,
                          episodes: eps)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/RSSFeedParserTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Add the URLSession FeedFetching implementation and commit**

Append to `Onda/Networking/RSSFeedParser.swift`:

```swift
struct RSSFeedClient: FeedFetching {
    typealias Transport = (URL) async throws -> Data
    private let transport: Transport
    private let parser = RSSFeedParser()

    init(transport: @escaping Transport = { try await URLSession.shared.data(from: $0).0 }) {
        self.transport = transport
    }

    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        let data = try await transport(url)
        guard let feed = parser.parse(data) else {
            throw NSError(domain: "Onda.RSS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No channel in feed"])
        }
        return feed
    }
}
```

```bash
git add Onda/Networking/RSSFeedParser.swift OndaTests/RSSFeedParserTests.swift OndaTests/Fixtures/feed_basic.xml OndaTests/Fixtures/feed_messy.xml
git commit -m "feat: tolerant RSSFeedParser + RSSFeedClient"
```

---

### Task 3: SubscriptionService

**Files:**
- Create: `Onda/Services/SubscriptionService.swift`
- Create: `OndaTests/SubscriptionServiceTests.swift`

**Interfaces:**
- Consumes: `PodcastDTO`, `FeedFetching`, `ParsedFeed`, SwiftData models from Plan 1.
- Produces:
  - `@Observable final class SubscriptionService`
  - `init(modelContext: ModelContext, feeds: FeedFetching)`
  - `func subscribe(to dto: PodcastDTO) async throws -> Podcast` — upserts `Podcast` (by `feedURL`), sets `isSubscribed = true`, creates `ShowSettings.makeDefault()`, fetches + upserts episodes
  - `func unsubscribe(_ podcast: Podcast)` — sets `isSubscribed = false` (keeps data)
  - `func refreshEpisodes(for podcast: Podcast) async throws` — re-fetches feed, inserts only new-guid episodes
  - Episode upsert never duplicates by `guid`.

- [ ] **Step 1: Write the failing service test**

Create `OndaTests/SubscriptionServiceTests.swift`:

```swift
//  SubscriptionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubFeeds: FeedFetching {
    var feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed { feed }
}

final class SubscriptionServiceTests: XCTestCase {
    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func dto() -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: "The Signal", artistName: "Ex",
                   feedUrl: URL(string: "https://ex.com/f.xml"),
                   artworkUrl600: URL(string: "https://ex.com/a.jpg"), primaryGenreName: "Technology")
    }

    private func feed(_ guids: [String]) -> ParsedFeed {
        ParsedFeed(title: "The Signal", author: "Ex", artworkURL: nil, category: "Technology",
                   episodes: guids.map {
                       ParsedEpisode(guid: $0, title: "T-\($0)", publishDate: .now, duration: 100,
                                     audioURL: URL(string: "https://ex.com/\($0).mp3")!,
                                     notes: "", chaptersURL: nil)
                   })
    }

    func test_subscribe_createsPodcastSettingsAndEpisodes() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertTrue(pod.isSubscribed)
        XCTAssertNotNil(pod.settings)
        XCTAssertEqual(pod.episodes.count, 2)
    }

    func test_refresh_addsOnlyNewEpisodes() async throws {
        let ctx = try context()
        var svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertEqual(pod.episodes.count, 1)

        svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b", "c"])))
        try await svc.refreshEpisodes(for: pod)
        XCTAssertEqual(pod.episodes.count, 3, "existing guid 'a' not duplicated")
    }

    func test_subscribeTwice_doesNotDuplicatePodcast() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        _ = try await svc.subscribe(to: dto())
        _ = try await svc.subscribe(to: dto())
        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/SubscriptionServiceTests`
Expected: FAIL — `cannot find 'SubscriptionService' in scope`.

- [ ] **Step 3: Write the service**

Create `Onda/Services/SubscriptionService.swift`:

```swift
//  SubscriptionService.swift
import Foundation
import SwiftData

@Observable
final class SubscriptionService {
    private let modelContext: ModelContext
    private let feeds: FeedFetching

    init(modelContext: ModelContext, feeds: FeedFetching) {
        self.modelContext = modelContext
        self.feeds = feeds
    }

    @discardableResult
    func subscribe(to dto: PodcastDTO) async throws -> Podcast {
        guard let feedURL = dto.feedUrl else {
            throw NSError(domain: "Onda.Subscribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Show has no RSS feed URL"])
        }
        let podcast = try existingPodcast(feedURL: feedURL) ?? {
            let p = Podcast(feedURL: feedURL, title: dto.collectionName, author: dto.artistName,
                            artworkURL: dto.artworkUrl600, category: dto.primaryGenreName ?? "Podcast",
                            itunesId: dto.collectionId)
            modelContext.insert(p)
            return p
        }()
        podcast.isSubscribed = true
        if podcast.settings == nil {
            let s = ShowSettings.makeDefault(); s.podcast = podcast; podcast.settings = s
            modelContext.insert(s)
        }
        try await refreshEpisodes(for: podcast)
        try modelContext.save()
        return podcast
    }

    func unsubscribe(_ podcast: Podcast) {
        podcast.isSubscribed = false
        try? modelContext.save()
    }

    func refreshEpisodes(for podcast: Podcast) async throws {
        let feed = try await feeds.fetchFeed(podcast.feedURL)
        let existing = Set(podcast.episodes.map(\.guid))
        for pe in feed.episodes where !existing.contains(pe.guid) {
            let ep = Episode(guid: pe.guid, title: pe.title, publishDate: pe.publishDate,
                             duration: pe.duration, audioURL: pe.audioURL, notes: pe.notes)
            ep.podcast = podcast
            podcast.episodes.append(ep)
            modelContext.insert(ep)
        }
        try modelContext.save()
    }

    private func existingPodcast(feedURL: URL) throws -> Podcast? {
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        return try modelContext.fetch(d).first
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/SubscriptionServiceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/SubscriptionService.swift OndaTests/SubscriptionServiceTests.swift
git commit -m "feat: SubscriptionService (subscribe/unsubscribe/refresh, guid-dedup upsert)"
```

---

### Task 4: Artwork placeholder view

**Files:**
- Create: `Onda/Discover/ArtworkView.swift`

**Interfaces:**
- Consumes: `AppTheme`.
- Produces: `ArtworkView(url: URL?, seed: String)` — a square view that async-loads `url` (disk-cached via `URLCache` default), falling back to a deterministic diagonal-stripe gradient derived from `seed` (mirrors the prototype's `artGrad`). Used by ShowCard, EpisodeRow, TrendingRow, and (Plan 3) Now Playing.

> This is the `ArtworkCache` consumer surface from the spec: it relies on `URLSession.shared`'s default `URLCache` (already disk-backed) so repeated grid scrolls don't refetch. No separate cache class is needed for v1.

- [ ] **Step 1: Write the artwork view**

Create `Onda/Discover/ArtworkView.swift`:

```swift
//  ArtworkView.swift
import SwiftUI

struct ArtworkView: View {
    @Environment(AppTheme.self) private var theme
    let url: URL?
    let seed: String

    private var hue: Double { Double(abs(seed.hashValue) % 360) }

    var body: some View {
        ZStack {
            gradient
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipped()
        .brutalBorder(width: 2.5)
    }

    private var gradient: some View {
        LinearGradient(
            colors: [Color(hue: hue / 360, saturation: 0.35, brightness: theme.appearance == .dark ? 0.32 : 0.82),
                     Color(hue: hue / 360, saturation: 0.30, brightness: theme.appearance == .dark ? 0.24 : 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Onda/Discover/ArtworkView.swift
git commit -m "feat: ArtworkView (async image over deterministic gradient fallback)"
```

---

### Task 5: Library grid + Show card

**Files:**
- Modify: `Onda/Shell/LibraryView.swift`
- Create: `Onda/Library/ShowCard.swift`

**Interfaces:**
- Consumes: `@Query` of subscribed `Podcast`, `ArtworkView`, brutal styles.
- Produces: `LibraryView` grid (2-col) of subscribed shows; tap a card → `EpisodeListView(podcast:)` (Task 6) via `NavigationStack`. `ShowCard(podcast:)`.

- [ ] **Step 1: Create the show card**

Create `Onda/Library/ShowCard.swift`:

```swift
//  ShowCard.swift
import SwiftUI

struct ShowCard: View {
    @Environment(AppTheme.self) private var theme
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(url: podcast.artworkURL, seed: podcast.title)
                .aspectRatio(1, contentMode: .fit)
                .hardShadow(offset: 4)
            Text(podcast.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                .lineLimit(2)
            Text(podcast.episodes.first?.title ?? "No episodes")
                .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
                .lineLimit(1)
        }
    }
}
```

- [ ] **Step 2: Rewrite LibraryView as a subscription grid**

Replace `Onda/Shell/LibraryView.swift`:

```swift
//  LibraryView.swift
import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                        .padding(.horizontal, 20).padding(.top, 56)

                    if shows.isEmpty {
                        Text("No shows yet — find some in Discover")
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    } else {
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(shows) { show in
                                NavigationLink(value: show) { ShowCard(podcast: show) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 120)
                    }
                }
            }
            .background(theme.color(.bg))
            .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **` (references `EpisodeListView` created next; if building before Task 6, temporarily stub it — but implement Task 6 before running).

- [ ] **Step 4: Commit**

```bash
git add Onda/Shell/LibraryView.swift Onda/Library/ShowCard.swift
git commit -m "feat: Library subscription grid + ShowCard"
```

---

### Task 6: Episode List screen

**Files:**
- Create: `Onda/Library/EpisodeListView.swift`, `Onda/Library/EpisodeRow.swift`

**Interfaces:**
- Consumes: `Podcast`, `Episode`, `SubscriptionService` (from environment), `ArtworkView`.
- Produces:
  - `EpisodeRow(episode:)` — title, relative date, duration, played/in-progress dot, a download button placeholder (wired in Plan 5), and a play affordance that (Plan 3) calls `PlaybackManager`. For this plan the row exposes `onPlay` / `onDownload` closures; Library passes no-op `onPlay` until Plan 3.
  - `EpisodeListView(podcast:)` — show header (art, name, category, Unsubscribe), episode rows sorted newest-first, pull-to-refresh calling `SubscriptionService.refreshEpisodes`.

- [ ] **Step 1: Create the episode row**

Create `Onda/Library/EpisodeRow.swift`:

```swift
//  EpisodeRow.swift
import SwiftUI

struct EpisodeRow: View {
    @Environment(AppTheme.self) private var theme
    let episode: Episode
    var onPlay: () -> Void = {}
    var onDownload: () -> Void = {}

    private var dateText: String {
        episode.publishDate.formatted(.relative(presentation: .named))
    }
    private var durationText: String {
        let m = Int(episode.duration) / 60
        return "\(m) min"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: episode.played ? "checkmark.circle" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(episode.played ? theme.color(.textTertiary) : theme.color(.accent))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.color(.text)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(dateText); Text("•"); Text(durationText)
                    if episode.playbackPosition > 1 && !episode.played {
                        Text("• In progress").foregroundStyle(theme.color(.accent))
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
            }
            Spacer(minLength: 8)
            Button(action: onDownload) {
                Image(systemName: episode.downloadedFile == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(theme.color(.textSecondary))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Create the episode list screen**

Create `Onda/Library/EpisodeListView.swift`:

```swift
//  EpisodeListView.swift
import SwiftUI
import SwiftData

struct EpisodeListView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast

    private var episodes: [Episode] {
        podcast.episodes.sorted { $0.publishDate > $1.publishDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().overlay(theme.color(.separator))
                ForEach(episodes) { ep in
                    EpisodeRow(episode: ep)
                    Divider().overlay(theme.color(.separator))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .background(theme.color(.bg))
        .refreshable { try? await subscriptions.refreshEpisodes(for: podcast) }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: podcast.artworkURL, seed: podcast.title)
                .frame(width: 96, height: 96).hardShadow(offset: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(podcast.title).brutalHeader(size: 20).foregroundStyle(theme.color(.text))
                Text(podcast.category).font(.system(size: 13))
                    .foregroundStyle(theme.color(.textTertiary))
                Button("Unsubscribe") {
                    subscriptions.unsubscribe(podcast); dismiss()
                }
                .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.color(.accent))
            }
            Spacer()
        }
        .padding(.top, 12)
    }
}
```

- [ ] **Step 3: Inject SubscriptionService in the app entry point**

Modify `Onda/OndaApp.swift` — add the service to `@State` and inject it. Replace the `body` and add init wiring:

```swift
//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var subscriptions: SubscriptionService

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            _subscriptions = State(initialValue:
                SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient()))
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .environment(subscriptions)
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 4: Build and run — verify Library→Episode List navigation**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`. (Full flow is verified after Task 7 wires Discover→subscribe, which populates the Library.)

- [ ] **Step 5: Commit**

```bash
git add Onda/Library/EpisodeListView.swift Onda/Library/EpisodeRow.swift Onda/OndaApp.swift
git commit -m "feat: Episode List screen + row, inject SubscriptionService"
```

---

### Task 7: Discover — search, categories, trending, Follow

**Files:**
- Modify: `Onda/Shell/DiscoverView.swift`
- Create: `Onda/Discover/TrendingRow.swift`

**Interfaces:**
- Consumes: `Searching` (ITunesSearchClient), `SubscriptionService`, `ArtworkView`.
- Produces: `DiscoverView` with a search field (debounced, calls `search(term:)`), category chips (static list from prototype), a trending list (topChartIds → lookup → rows), and a Follow button per row that calls `subscribe(to:)`. `TrendingRow(dto:isSubscribed:onFollow:)`.

> `DiscoverView` owns transient search/trending arrays in `@State` (view-local UI state, not domain data — allowed by MV). The `Searching` client is created in the app entry point and injected.

- [ ] **Step 1: Create the trending row**

Create `Onda/Discover/TrendingRow.swift`:

```swift
//  TrendingRow.swift
import SwiftUI

struct TrendingRow: View {
    @Environment(AppTheme.self) private var theme
    let dto: PodcastDTO
    let isSubscribed: Bool
    var onFollow: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: dto.artworkUrl600, seed: dto.collectionName)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(dto.collectionName).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(1)
                Text(dto.primaryGenreName ?? "Podcast").font(.system(size: 13))
                    .foregroundStyle(theme.color(.textTertiary))
            }
            Spacer(minLength: 8)
            Button(action: onFollow) {
                Text(isSubscribed ? "Following" : "Follow")
                    .font(.system(size: 13, weight: .bold)).textCase(.uppercase)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(isSubscribed ? theme.color(.textTertiary) : theme.color(.accent))
                    .brutalBorder(width: 2)
            }.buttonStyle(.plain).disabled(isSubscribed)
        }
        .padding(10)
        .brutalBorder(width: 2)
        .hardShadow(offset: 3)
    }
}
```

- [ ] **Step 2: Rewrite DiscoverView**

Replace `Onda/Shell/DiscoverView.swift`:

```swift
//  DiscoverView.swift
import SwiftUI
import SwiftData

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(ITunesSearchClientBox.self) private var clientBox
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]

    @State private var query = ""
    @State private var results: [PodcastDTO] = []
    @State private var trending: [PodcastDTO] = []
    @State private var loading = false

    private let categories = ["Technology", "Comedy", "News", "Business", "Health", "Science"]
    private var subscribedFeeds: Set<URL> { Set(subs.map(\.feedURL)) }

    private func isSubscribed(_ dto: PodcastDTO) -> Bool {
        dto.feedUrl.map(subscribedFeeds.contains) ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Discover").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                    .padding(.top, 56)

                searchField
                categoryChips

                Text(results.isEmpty ? "Trending Today" : "Results")
                    .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))

                ForEach(results.isEmpty ? trending : results, id: \.collectionId) { dto in
                    TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                        Task { try? await subscriptions.subscribe(to: dto) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .background(theme.color(.bg))
        .task { await loadTrending() }
        .onChange(of: query) { _, new in Task { await runSearch(new) } }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
            TextField("Search shows & episodes", text: $query)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button { query = cat } label: {
                        Text(cat).brutalHeader(size: 11.5).foregroundStyle(theme.color(.text))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func loadTrending() async {
        guard trending.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let ids = try await clientBox.client.topChartIds(limit: 25)
            trending = try await clientBox.client.lookup(ids: Array(ids.prefix(20)))
        } catch { trending = [] }
    }

    private func runSearch(_ term: String) async {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(300))   // debounce
        guard t == query.trimmingCharacters(in: .whitespaces) else { return }
        results = (try? await clientBox.client.search(term: t)) ?? []
    }
}
```

- [ ] **Step 3: Add the injectable client box and wire it in the app**

Create `Onda/Networking/ITunesSearchClientBox.swift`:

```swift
//  ITunesSearchClientBox.swift
import Foundation

@Observable
final class ITunesSearchClientBox {
    let client: any Searching
    init(client: any Searching) { self.client = client }
}
```

Modify `Onda/OndaApp.swift` to add and inject it:

```swift
//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var subscriptions: SubscriptionService
    @State private var clientBox = ITunesSearchClientBox(client: ITunesSearchClient())

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            _subscriptions = State(initialValue:
                SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient()))
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .environment(subscriptions)
                .environment(clientBox)
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 4: Build and run the full discovery→subscribe→library flow**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Then launch (needs network in the simulator):
```bash
xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build install
xcrun simctl launch booted com.onda.Onda
```
Expected: Discover shows trending; searching "slow burn" returns results; tapping Follow moves a show into Library; Library card opens the Episode List with episodes.

- [ ] **Step 5: Commit**

```bash
git add Onda/Shell/DiscoverView.swift Onda/Discover/TrendingRow.swift Onda/Networking/ITunesSearchClientBox.swift Onda/OndaApp.swift
git commit -m "feat: Discover tab — search, categories, trending, Follow; end-to-end subscribe flow"
```

---

## Self-Review

- **Spec coverage:** iTunes Search (search) ✓; two-hop trending (topChartIds → lookup) ✓; client-side RSS parsing incl. Podcasting-2.0 `<podcast:chapters>` URL ✓; tolerant parser for messy feeds ✓; subscribe/unsubscribe with lazy `ShowSettings.makeDefault()` ✓; Library grid ✓; Episode List screen (new) ✓; artwork caching via default `URLCache` ✓. Chapters/ad markers are *linked* here (`chaptersURL`); fetching+storing `Chapter` rows happens in Plan 3 (Now Playing displays them) — noted so it isn't lost.
- **Placeholder scan:** `EpisodeRow.onPlay` is an intentional injected closure (no-op until Plan 3 supplies playback) — documented in the interface, not a hidden TODO. All code steps are complete.
- **Type consistency:** `PodcastDTO`, `ParsedFeed`/`ParsedEpisode`, `Searching`, `FeedFetching`, `SubscriptionService(modelContext:feeds:)` are used identically across tasks. `EpisodeRow(episode:onPlay:onDownload:)` signature matches what Plan 3/5 will call. Model initializers match Plan 1's "Produces" block.
