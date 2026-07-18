# Private Feed Token Keychain Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the secret token in private/paid podcast feed URLs out of the plaintext SwiftData
store and into Keychain, while keeping `Podcast.feedURL` working as the existing identity key
everywhere it's used today.

**Architecture:** For `isPrivateFeed` podcasts, `Podcast.feedURL` stores a synthetic placeholder
URL (`onda-private-feed://<sha256-of-real-url>`) instead of the real tokenized URL. The real URL
lives only in Keychain, keyed by that same hash, via a new `PrivateFeedTokenStore`. A single
resolution point in `SubscriptionService.refreshEpisodes` swaps the placeholder for the real URL
before fetching. A one-time, idempotent, launch-time migration converts existing installs.

**Tech Stack:** Swift 6, SwiftData, XCTest, CryptoKit (SHA-256), Security framework (Keychain).

## Global Constraints

- Deployment target iOS 17+ (from `project.yml`).
- Scope is `Podcast.feedURL` only — `Episode.audioURL`/`chaptersURL`/`transcriptURL` are
  explicitly out of scope (per spec).
- Keychain items: `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`,
  `kSecAttrSynchronizable = true` (syncs via iCloud Keychain).
- Migration runs eagerly at app launch, is idempotent, and is fail-safe (a podcast whose
  Keychain write fails is left with its real `feedURL` untouched and retried on next launch).
- After adding any new `.swift` file under `Onda/` or `OndaTests/`, run `xcodegen generate`
  before building/testing — XcodeGen picks up new files via folder references
  (see root `CLAUDE.md`).
- No SwiftData schema changes are needed — `Podcast.feedURL` and `isPrivateFeed` already exist;
  only the *value* written into `feedURL` for private feeds changes.

---

### Task 1: `PrivateFeedIdentity` — hashing and placeholder URLs

**Files:**
- Create: `Onda/Services/PrivateFeedIdentity.swift`
- Test: `OndaTests/PrivateFeedIdentityTests.swift`

**Interfaces:**
- Produces:
  - `enum PrivateFeedIdentity`
  - `static func hash(for url: URL) -> String` — hex-encoded SHA-256 of `url.absoluteString`
  - `static func placeholderURL(forHash hash: String) -> URL` — `onda-private-feed://<hash>`
  - `static func isPlaceholder(_ url: URL) -> Bool` — true iff `url.scheme == "onda-private-feed"`

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/PrivateFeedIdentityTests.swift`:

```swift
//  PrivateFeedIdentityTests.swift
import XCTest
@testable import Onda

final class PrivateFeedIdentityTests: XCTestCase {
    func test_hash_isDeterministic() {
        let url = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        XCTAssertEqual(PrivateFeedIdentity.hash(for: url), PrivateFeedIdentity.hash(for: url))
    }

    func test_hash_differsForDifferentURLs() {
        let a = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        let b = URL(string: "https://feeds.example.com/private.xml?token=xyz")!
        XCTAssertNotEqual(PrivateFeedIdentity.hash(for: a), PrivateFeedIdentity.hash(for: b))
    }

    func test_placeholderURL_usesPlaceholderSchemeAndHash() {
        let hash = "abc123"
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        XCTAssertEqual(placeholder.scheme, "onda-private-feed")
        XCTAssertEqual(placeholder.host, hash)
    }

    func test_isPlaceholder_trueForPlaceholder_falseForRealURL() {
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: "abc123")
        let real = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(placeholder))
        XCTAssertFalse(PrivateFeedIdentity.isPlaceholder(real))
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and run the tests to verify they fail to build**

```bash
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedIdentityTests
```

Expected: BUILD FAILED — `PrivateFeedIdentity` is not defined.

- [ ] **Step 3: Implement `PrivateFeedIdentity`**

Create `Onda/Services/PrivateFeedIdentity.swift`:

```swift
//  PrivateFeedIdentity.swift
import Foundation
import CryptoKit

/// Derives a non-secret identity for a private/paid feed's real (tokenized) URL, and the
/// placeholder URL that stands in for it in SwiftData. See
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
enum PrivateFeedIdentity {
    static let placeholderScheme = "onda-private-feed"

    static func hash(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func placeholderURL(forHash hash: String) -> URL {
        URL(string: "\(placeholderScheme)://\(hash)")!
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        url.scheme == placeholderScheme
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedIdentityTests
```

Expected: TEST SUCCEEDED, all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/PrivateFeedIdentity.swift OndaTests/PrivateFeedIdentityTests.swift project.yml Onda.xcodeproj
git commit -m "feat: add PrivateFeedIdentity for hashing private feed URLs"
```

---

### Task 2: `PrivateFeedTokenStore` — Keychain-backed token storage

**Files:**
- Create: `Onda/Services/PrivateFeedTokenStore.swift`
- Test: `OndaTests/PrivateFeedTokenStoreTests.swift`

**Interfaces:**
- Consumes: none (Security framework only)
- Produces:
  - `protocol PrivateFeedTokenStoring: Sendable { func store(realURL: URL, hash: String) throws; func realURL(forHash hash: String) throws -> URL?; func delete(hash: String) throws }`
  - `final class PrivateFeedTokenStore: PrivateFeedTokenStoring`, `init(service: String = "com.chasegilliam.onda.privateFeedTokens")`
  - `struct PrivateFeedTokenStoreError: Error { let status: OSStatus }`

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/PrivateFeedTokenStoreTests.swift`:

```swift
//  PrivateFeedTokenStoreTests.swift
import XCTest
@testable import Onda

final class PrivateFeedTokenStoreTests: XCTestCase {
    private var store: PrivateFeedTokenStore!

    override func setUp() {
        super.setUp()
        store = PrivateFeedTokenStore(service: "com.chasegilliam.onda.privateFeedTokens.tests")
    }

    override func tearDown() {
        try? store.delete(hash: "hash-a")
        try? store.delete(hash: "hash-b")
        super.tearDown()
    }

    func test_store_thenRealURL_returnsStoredURL() throws {
        let url = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        try store.store(realURL: url, hash: "hash-a")
        XCTAssertEqual(try store.realURL(forHash: "hash-a"), url)
    }

    func test_realURL_forUnknownHash_returnsNil() throws {
        XCTAssertNil(try store.realURL(forHash: "hash-b"))
    }

    func test_store_overwritesExistingValue() throws {
        let first = URL(string: "https://feeds.example.com/a.xml?token=1")!
        let second = URL(string: "https://feeds.example.com/a.xml?token=2")!
        try store.store(realURL: first, hash: "hash-a")
        try store.store(realURL: second, hash: "hash-a")
        XCTAssertEqual(try store.realURL(forHash: "hash-a"), second)
    }

    func test_delete_removesEntry() throws {
        let url = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        try store.store(realURL: url, hash: "hash-a")
        try store.delete(hash: "hash-a")
        XCTAssertNil(try store.realURL(forHash: "hash-a"))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail to build**

```bash
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedTokenStoreTests
```

Expected: BUILD FAILED — `PrivateFeedTokenStore` is not defined.

- [ ] **Step 3: Implement `PrivateFeedTokenStore`**

Create `Onda/Services/PrivateFeedTokenStore.swift`:

```swift
//  PrivateFeedTokenStore.swift
import Foundation
import Security

/// Keychain-backed storage for the real (tokenized) URL of a private/paid feed, keyed by
/// `PrivateFeedIdentity.hash(for:)`. SwiftData never sees the real URL — see
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
protocol PrivateFeedTokenStoring: Sendable {
    func store(realURL: URL, hash: String) throws
    func realURL(forHash hash: String) throws -> URL?
    func delete(hash: String) throws
}

struct PrivateFeedTokenStoreError: Error {
    let status: OSStatus
}

final class PrivateFeedTokenStore: PrivateFeedTokenStoring {
    private let service: String

    init(service: String = "com.chasegilliam.onda.privateFeedTokens") {
        self.service = service
    }

    func store(realURL: URL, hash: String) throws {
        try? delete(hash: hash)   // overwrite semantics
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecValueData as String: Data(realURL.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PrivateFeedTokenStoreError(status: status) }
    }

    func realURL(forHash hash: String) throws -> URL? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string) else {
            throw PrivateFeedTokenStoreError(status: status)
        }
        return url
    }

    func delete(hash: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PrivateFeedTokenStoreError(status: status)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedTokenStoreTests
```

Expected: TEST SUCCEEDED, all 4 tests pass. (Runs against the simulator's real Keychain under a
test-only service name, cleaned up in `tearDown`.)

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/PrivateFeedTokenStore.swift OndaTests/PrivateFeedTokenStoreTests.swift project.yml Onda.xcodeproj
git commit -m "feat: add Keychain-backed PrivateFeedTokenStore"
```

---

### Task 3: Wire `SubscriptionService` through the token store

**Files:**
- Modify: `Onda/Services/SubscriptionService.swift:12-24` (init/properties), `:53-65`
  (`subscribeToFeedURL`), `:137-155` (`refreshEpisodes`)
- Modify: `OndaTests/SubscriptionServiceTests.swift`

**Interfaces:**
- Consumes: `PrivateFeedIdentity.hash(for:)`, `.placeholderURL(forHash:)` (Task 1);
  `PrivateFeedTokenStoring` (Task 2)
- Produces: `SubscriptionService.init(modelContext:feeds:tokenStore:)` — `tokenStore` defaults to
  `PrivateFeedTokenStore()`, existing call sites that don't pass it are unaffected.

- [ ] **Step 1: Write/update the failing tests**

In `OndaTests/SubscriptionServiceTests.swift`, add a fake token store near the top (after the
existing `StubFeeds`/`FailingFeeds`):

```swift
private final class InMemoryTokenStore: PrivateFeedTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: URL] = [:]

    func store(realURL: URL, hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[hash] = realURL
    }

    func realURL(forHash hash: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return storage[hash]
    }

    func delete(hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: hash)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

private struct RequireURLFeeds: FeedFetching {
    let expected: URL
    let feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        guard url == expected else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected URL: \(url)"])
        }
        return feed
    }
}
```

Replace `test_subscribeToFeedURL_createsPrivatePodcastFromChannelMetadata` (its `feedURL`
assertion is now wrong — `feedURL` becomes a placeholder, not the real URL) with:

```swift
func test_subscribeToFeedURL_createsPrivatePodcastFromChannelMetadata() async throws {
    let ctx = try context()
    let tokenStore = InMemoryTokenStore()
    let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b"])),
                                  tokenStore: tokenStore)
    let url = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
    let pod = try await svc.subscribeToFeedURL(url)
    XCTAssertTrue(pod.isPrivateFeed)
    XCTAssertTrue(pod.isSubscribed)
    XCTAssertEqual(pod.feedURL.scheme, "onda-private-feed", "feedURL is replaced with a placeholder")
    XCTAssertNotEqual(pod.feedURL, url, "the real tokenized URL must not be stored in SwiftData")
    XCTAssertEqual(try tokenStore.realURL(forHash: pod.feedURL.host!), url,
                  "the real URL is retrievable from the token store")
    XCTAssertEqual(pod.title, "The Signal", "title comes from the feed channel")
    XCTAssertEqual(pod.author, "Ex")
    XCTAssertEqual(pod.category, "Technology")
    XCTAssertNil(pod.itunesId)
    XCTAssertNotNil(pod.settings)
    XCTAssertEqual(pod.episodes.count, 2)
}
```

Update the other two `subscribeToFeedURL` tests to pass `tokenStore: InMemoryTokenStore()`:

```swift
func test_subscribeToFeedURL_autoDownloadsNewestEpisode() async throws {
    let ctx = try context()
    let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                  tokenStore: InMemoryTokenStore())
    var downloaded: [String] = []
    svc.downloadEpisode = { downloaded.append($0.guid) }
    _ = try await svc.subscribeToFeedURL(URL(string: "https://ex.com/p.xml?t=k")!)
    XCTAssertEqual(downloaded, ["a"])
}

func test_subscribeToFeedURL_twice_doesNotDuplicatePodcast() async throws {
    let ctx = try context()
    let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                  tokenStore: InMemoryTokenStore())
    let url = URL(string: "https://ex.com/p.xml?t=k")!
    _ = try await svc.subscribeToFeedURL(url)
    let again = try await svc.subscribeToFeedURL(url)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
    XCTAssertTrue(again.isSubscribed)
}
```

Add two new tests for `refreshEpisodes` resolution, after `test_refresh_addsOnlyNewEpisodes`:

```swift
func test_refreshEpisodes_privateFeed_resolvesRealURLFromTokenStore() async throws {
    let ctx = try context()
    let tokenStore = InMemoryTokenStore()
    let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
    let subscribeSvc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                           tokenStore: tokenStore)
    let pod = try await subscribeSvc.subscribeToFeedURL(realURL)

    // If refreshEpisodes fetched the placeholder URL instead of resolving the real one,
    // RequireURLFeeds throws and this call fails.
    let refreshSvc = SubscriptionService(modelContext: ctx,
                                         feeds: RequireURLFeeds(expected: realURL, feed: feed(["a", "b"])),
                                         tokenStore: tokenStore)
    try await refreshSvc.refreshEpisodes(for: pod)
    XCTAssertEqual(pod.episodes.count, 2)
}

func test_refreshEpisodes_privateFeed_missingToken_throws() async throws {
    let ctx = try context()
    let tokenStore = InMemoryTokenStore()
    let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
    let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                  tokenStore: tokenStore)
    let pod = try await svc.subscribeToFeedURL(realURL)
    tokenStore.removeAll()
    do {
        try await svc.refreshEpisodes(for: pod)
        XCTFail("expected throw when the Keychain token is missing")
    } catch { /* expected */ }
}
```

- [ ] **Step 2: Run the new/updated tests to verify they fail**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/SubscriptionServiceTests
```

Expected: BUILD FAILED or test failures — `SubscriptionService.init` has no `tokenStore`
parameter yet, and `subscribeToFeedURL`/`refreshEpisodes` don't touch a token store.

- [ ] **Step 3: Update `SubscriptionService`**

In `Onda/Services/SubscriptionService.swift`, add the property and update `init` (around line 13):

```swift
    private let modelContext: ModelContext
    private let feeds: FeedFetching
    private let tokenStore: PrivateFeedTokenStoring
```

```swift
    init(modelContext: ModelContext, feeds: FeedFetching,
         tokenStore: PrivateFeedTokenStoring = PrivateFeedTokenStore()) {
        self.modelContext = modelContext
        self.feeds = feeds
        self.tokenStore = tokenStore
    }
```

Replace `subscribeToFeedURL(_:)` (currently lines 53-65):

```swift
    /// Subscribe to a feed directly by URL (private/paid tokenized feeds). Show metadata comes
    /// from the feed channel itself; nothing is persisted if the fetch fails. The real URL is
    /// written to Keychain and only a non-secret placeholder is stored in SwiftData — see
    /// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
    @discardableResult
    func subscribeToFeedURL(_ url: URL) async throws -> Podcast {
        let parsed = try await feeds.fetchFeed(url)   // validate before inserting anything
        let hash = PrivateFeedIdentity.hash(for: url)
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        let podcast: Podcast
        if let existing = try existingPodcast(feedURL: placeholder) {
            podcast = existing
        } else {
            try tokenStore.store(realURL: url, hash: hash)
            let p = Podcast(feedURL: placeholder, title: parsed.title, author: parsed.author,
                            artworkURL: parsed.artworkURL, category: parsed.category,
                            itunesId: nil, isPrivateFeed: true)
            modelContext.insert(p)
            podcast = p
        }
        try await activateSubscription(podcast)
        return podcast
    }
```

Replace `refreshEpisodes(for:)` (currently lines 137-155) — only the first line changes, the rest
of the body is unchanged:

```swift
    func refreshEpisodes(for podcast: Podcast) async throws {
        let fetchURL: URL
        if podcast.isPrivateFeed {
            guard let realURL = try tokenStore.realURL(forHash: podcast.feedURL.host ?? "") else {
                throw NSError(domain: "Onda.Subscribe", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Private feed token not found"])
            }
            fetchURL = realURL
        } else {
            fetchURL = podcast.feedURL
        }
        let feed = try await feeds.fetchFeed(fetchURL)
        let existing = Set(podcast.episodes.map(\.guid))
        // Build new episodes first and extend the relationship ONCE — per-item appends to a
        // SwiftData relationship array are quadratic (same class of hang as the cue persist).
        var added: [Episode] = []
        for pe in feed.episodes where !existing.contains(pe.guid) {
            let ep = Episode(guid: pe.guid, title: pe.title, publishDate: pe.publishDate,
                             duration: pe.duration, audioURL: pe.audioURL, notes: pe.notes,
                             chaptersURL: pe.chaptersURL,
                             transcriptURL: pe.transcriptURL, transcriptType: pe.transcriptType)
            modelContext.insert(ep)
            added.append(ep)
        }
        guard !added.isEmpty else { return }
        podcast.episodes.append(contentsOf: added)
        for ep in added { ep.podcast = podcast }
        try modelContext.save()
    }
```

- [ ] **Step 4: Run the full test file to verify it passes**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/SubscriptionServiceTests
```

Expected: TEST SUCCEEDED, all tests pass (existing + new).

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/SubscriptionService.swift OndaTests/SubscriptionServiceTests.swift
git commit -m "feat: resolve private feed tokens through Keychain in SubscriptionService"
```

---

### Task 4: `PrivateFeedTokenMigration` — one-time launch migration

**Files:**
- Create: `Onda/Services/PrivateFeedTokenMigration.swift`
- Test: `OndaTests/PrivateFeedTokenMigrationTests.swift`

**Interfaces:**
- Consumes: `PrivateFeedIdentity` (Task 1), `PrivateFeedTokenStoring` (Task 2), `Podcast`
  (`Onda/Models/Podcast.swift`)
- Produces: `enum PrivateFeedTokenMigration { static func run(context: ModelContext, tokenStore: PrivateFeedTokenStoring) }`

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/PrivateFeedTokenMigrationTests.swift`:

```swift
//  PrivateFeedTokenMigrationTests.swift
import XCTest
import SwiftData
@testable import Onda

private final class InMemoryTokenStore: PrivateFeedTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: URL] = [:]

    func store(realURL: URL, hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[hash] = realURL
    }

    func realURL(forHash hash: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return storage[hash]
    }

    func delete(hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: hash)
    }
}

final class PrivateFeedTokenMigrationTests: XCTestCase {
    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_run_migratesPrivatePodcastWithRealFeedURL() throws {
        let ctx = try context()
        let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let pod = Podcast(feedURL: realURL, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        ctx.insert(pod)
        try ctx.save()

        let tokenStore = InMemoryTokenStore()
        PrivateFeedTokenMigration.run(context: ctx, tokenStore: tokenStore)

        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(pod.feedURL), "feedURL rewritten to placeholder")
        let hash = pod.feedURL.host!
        XCTAssertEqual(try tokenStore.realURL(forHash: hash), realURL, "real URL stored in token store")
    }

    func test_run_skipsAlreadyMigratedPodcast() throws {
        let ctx = try context()
        let hash = PrivateFeedIdentity.hash(for: URL(string: "https://feeds.example.com/x.xml?t=1")!)
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        let pod = Podcast(feedURL: placeholder, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: nil, isSubscribed: true, isPrivateFeed: true)
        ctx.insert(pod)
        try ctx.save()

        let tokenStore = InMemoryTokenStore()
        PrivateFeedTokenMigration.run(context: ctx, tokenStore: tokenStore)

        XCTAssertEqual(pod.feedURL, placeholder, "already-placeholder feedURL left untouched")
        XCTAssertNil(try tokenStore.realURL(forHash: hash), "no token written for an already-migrated podcast")
    }

    func test_run_leavesPublicPodcastsUntouched() throws {
        let ctx = try context()
        let realURL = URL(string: "https://ex.com/public.xml")!
        let pod = Podcast(feedURL: realURL, title: "T", author: "A", artworkURL: nil,
                          category: "Tech", itunesId: 1, isSubscribed: true, isPrivateFeed: false)
        ctx.insert(pod)
        try ctx.save()

        PrivateFeedTokenMigration.run(context: ctx, tokenStore: InMemoryTokenStore())

        XCTAssertEqual(pod.feedURL, realURL, "public podcasts are never touched by migration")
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail to build**

```bash
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedTokenMigrationTests
```

Expected: BUILD FAILED — `PrivateFeedTokenMigration` is not defined.

- [ ] **Step 3: Implement `PrivateFeedTokenMigration`**

Create `Onda/Services/PrivateFeedTokenMigration.swift`:

```swift
//  PrivateFeedTokenMigration.swift
import Foundation
import SwiftData

/// One-time, idempotent, fail-safe migration of existing private-feed podcasts: moves each
/// real tokenized feedURL into Keychain and rewrites the SwiftData row to the non-secret
/// placeholder form. Run at app launch, before any UI is shown. A podcast whose Keychain write
/// fails is left with its real feedURL untouched and is retried on the next launch. See
/// docs/superpowers/specs/2026-07-18-private-feed-token-keychain-design.md.
enum PrivateFeedTokenMigration {
    static func run(context: ModelContext, tokenStore: PrivateFeedTokenStoring) {
        let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isPrivateFeed == true })
        guard let podcasts = try? context.fetch(descriptor) else { return }
        var didMigrateAny = false
        for podcast in podcasts where !PrivateFeedIdentity.isPlaceholder(podcast.feedURL) {
            let realURL = podcast.feedURL
            let hash = PrivateFeedIdentity.hash(for: realURL)
            guard (try? tokenStore.store(realURL: realURL, hash: hash)) != nil else { continue }
            podcast.feedURL = PrivateFeedIdentity.placeholderURL(forHash: hash)
            didMigrateAny = true
        }
        if didMigrateAny { try? context.save() }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PrivateFeedTokenMigrationTests
```

Expected: TEST SUCCEEDED, all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/PrivateFeedTokenMigration.swift OndaTests/PrivateFeedTokenMigrationTests.swift project.yml Onda.xcodeproj
git commit -m "feat: add launch-time migration of private feed tokens into Keychain"
```

---

### Task 5: Wire it into `OndaApp` and verify end-to-end

**Files:**
- Modify: `Onda/OndaApp.swift:23-32`

**Interfaces:**
- Consumes: `PrivateFeedTokenStore()` (Task 2), `PrivateFeedTokenMigration.run(context:tokenStore:)`
  (Task 4), `SubscriptionService.init(modelContext:feeds:tokenStore:)` (Task 3)
- Produces: nothing new — this is app wiring only.

- [ ] **Step 1: Update `OndaApp.init()`**

In `Onda/OndaApp.swift`, the `init()` currently starts (lines 23-30):

```swift
    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            let settings = AppSettings()
            _appSettings = State(initialValue: settings)
            let subs = SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient())
```

Change it to run the migration and inject the token store:

```swift
    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            let tokenStore = PrivateFeedTokenStore()
            PrivateFeedTokenMigration.run(context: c.mainContext, tokenStore: tokenStore)
            let settings = AppSettings()
            _appSettings = State(initialValue: settings)
            let subs = SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient(),
                                           tokenStore: tokenStore)
```

The rest of `init()` is unchanged.

- [ ] **Step 2: Build the app target**

```bash
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: TEST SUCCEEDED, all tests pass (no regressions in unrelated suites).

- [ ] **Step 4: Run SwiftLint**

```bash
swiftlint lint
```

Expected: no new violations introduced by this change.

- [ ] **Step 5: Manual smoke test in the simulator**

Launch the app in the iOS 17 simulator (via `xcodebuild build` output or Xcode), open Discover →
add-by-URL, subscribe to a fake tokenized URL (e.g. `https://httpbin.org` won't parse as RSS, so
use any reachable test RSS feed URL with a `?token=...` query string), confirm the subscribe
succeeds and the show appears in Library with its "PRIVATE" badge, then pull-to-refresh the show
and confirm it still refreshes successfully (proving the Keychain round-trip works against the
real Keychain, not just the in-memory test double).

- [ ] **Step 6: Commit**

```bash
git add Onda/OndaApp.swift
git commit -m "feat: wire private feed token migration and Keychain store into OndaApp"
```
