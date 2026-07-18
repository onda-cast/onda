# Private Podcast Feeds (Add by URL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user subscribe to tokenized private/paid RSS feeds by pasting the URL, with the show flagged private and excluded from recommendation signals.

**Architecture:** A new `subscribeToFeedURL` path on `SubscriptionService` builds the `Podcast` from the feed's own channel metadata (no iTunes DTO), sharing the existing subscribe tail (settings, refresh, auto-download). UI is an `AddFeedSheet` opened from a button beside the Discover search field, with a fetch-preview-confirm flow. A new `Podcast.isPrivateFeed` flag drives a Library badge and exclusion from `TasteProfileBuilder`.

**Tech Stack:** SwiftUI, SwiftData, XCTest, XcodeGen.

Spec: `docs/superpowers/specs/2026-07-17-private-podcast-feeds-design.md`

## Global Constraints

- iOS 17+, SwiftUI "MV" pattern — no ViewModel layer; services are `@Observable` and injected via `.environment(...)` in `OndaApp.swift`.
- Neo-brutalist theme: use `brutalBorder(width:)`, `brutalHeader(size:)`, `hardShadow(offset:)` from `Onda/Theme/BrutalStyle.swift`; colors via `theme.color(...)`.
- Tap targets ≥44pt and VoiceOver labels on new controls (established UX convention).
- After adding new files, run `xcodegen generate` (project uses folder references via XcodeGen).
- Build/test destination: `platform=iOS Simulator,name=iPhone 17`.

---

### Task 1: `Podcast.isPrivateFeed` model flag

**Files:**
- Modify: `Onda/Models/Podcast.swift`
- Test: `OndaTests/ModelTests.swift`

**Interfaces:**
- Produces: `Podcast.isPrivateFeed: Bool` (stored, defaults `false`); `Podcast.init(feedURL:title:author:artworkURL:category:itunesId:isSubscribed:isPrivateFeed:)` with `isPrivateFeed: Bool = false` — existing call sites compile unchanged.

- [ ] **Step 1: Write the failing test**

Append inside the existing test class in `OndaTests/ModelTests.swift` (match its existing in-memory-container helper style; if the class has a `context()`/`ctx()` helper, reuse it):

```swift
func test_podcast_isPrivateFeed_defaultsFalseAndPersists() throws {
    let c = try ModelContainer(for: Schema(ondaSchema),
                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = ModelContext(c)
    let pub = Podcast(feedURL: URL(string: "https://ex.com/pub.xml")!, title: "Pub",
                      author: "A", artworkURL: nil, category: "Tech", itunesId: 1)
    let priv = Podcast(feedURL: URL(string: "https://ex.com/priv.xml?token=s3cret")!, title: "Priv",
                       author: "A", artworkURL: nil, category: "Tech", itunesId: nil,
                       isPrivateFeed: true)
    ctx.insert(pub); ctx.insert(priv); try ctx.save()
    XCTAssertFalse(pub.isPrivateFeed, "default is public")
    XCTAssertTrue(priv.isPrivateFeed)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/ModelTests/test_podcast_isPrivateFeed_defaultsFalseAndPersists
```
Expected: BUILD FAILURE — `extra argument 'isPrivateFeed' in call` / `value of type 'Podcast' has no member 'isPrivateFeed'`.

- [ ] **Step 3: Add the property**

In `Onda/Models/Podcast.swift`, add the stored property after `isSubscribed` and extend the init:

```swift
    var isSubscribed: Bool
    /// True for shows added via a tokenized private/paid feed URL. The URL contains a secret,
    /// so private shows are kept out of anything that leaves the device (taste profile, future
    /// share/export surfaces).
    var isPrivateFeed: Bool = false
```

```swift
    init(feedURL: URL, title: String, author: String, artworkURL: URL?,
         category: String, itunesId: Int?, isSubscribed: Bool = false,
         isPrivateFeed: Bool = false) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.category = category
        self.itunesId = itunesId
        self.isSubscribed = isSubscribed
        self.isPrivateFeed = isPrivateFeed
    }
```

- [ ] **Step 4: Run test to verify it passes**

Same command as Step 2. Expected: `Test Case ... passed`.

- [ ] **Step 5: Commit**

```bash
git add Onda/Models/Podcast.swift OndaTests/ModelTests.swift
git commit -m "feat: add Podcast.isPrivateFeed flag"
```

---

### Task 2: `SubscriptionService.subscribeToFeedURL` + `previewFeed`

**Files:**
- Modify: `Onda/Services/SubscriptionService.swift`
- Test: `OndaTests/SubscriptionServiceTests.swift`

**Interfaces:**
- Consumes: `Podcast.init(... isPrivateFeed:)` from Task 1; existing `FeedFetching.fetchFeed(_:) -> ParsedFeed`.
- Produces:
  - `func previewFeed(_ url: URL) async throws -> ParsedFeed` — used by AddFeedSheet (Task 4) for the preview step; pure fetch, persists nothing.
  - `@discardableResult func subscribeToFeedURL(_ url: URL) async throws -> Podcast` — used by AddFeedSheet on Subscribe.

- [ ] **Step 1: Write the failing tests**

In `OndaTests/SubscriptionServiceTests.swift`, add a throwing stub next to the existing `StubFeeds`:

```swift
private struct FailingFeeds: FeedFetching {
    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        throw NSError(domain: "test", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "not found"])
    }
}
```

Append these tests to the class (they reuse the existing `context()` and `feed(_:)` helpers):

```swift
    func test_subscribeToFeedURL_createsPrivatePodcastFromChannelMetadata() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b"])))
        let url = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let pod = try await svc.subscribeToFeedURL(url)
        XCTAssertTrue(pod.isPrivateFeed)
        XCTAssertTrue(pod.isSubscribed)
        XCTAssertEqual(pod.feedURL, url)
        XCTAssertEqual(pod.title, "The Signal", "title comes from the feed channel")
        XCTAssertEqual(pod.author, "Ex")
        XCTAssertEqual(pod.category, "Technology")
        XCTAssertNil(pod.itunesId)
        XCTAssertNotNil(pod.settings)
        XCTAssertEqual(pod.episodes.count, 2)
    }

    func test_subscribeToFeedURL_autoDownloadsNewestEpisode() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        var downloaded: [String] = []
        svc.downloadEpisode = { downloaded.append($0.guid) }
        _ = try await svc.subscribeToFeedURL(URL(string: "https://ex.com/p.xml?t=k")!)
        XCTAssertEqual(downloaded, ["a"])
    }

    func test_subscribeToFeedURL_twice_doesNotDuplicatePodcast() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let url = URL(string: "https://ex.com/p.xml?t=k")!
        _ = try await svc.subscribeToFeedURL(url)
        let again = try await svc.subscribeToFeedURL(url)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertTrue(again.isSubscribed)
    }

    func test_subscribeToFeedURL_fetchFailure_persistsNothing() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: FailingFeeds())
        do {
            _ = try await svc.subscribeToFeedURL(URL(string: "https://ex.com/bad.xml")!)
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 0)
    }

    func test_subscribe_publicPath_isNotPrivate() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertFalse(pod.isPrivateFeed)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/SubscriptionServiceTests
```
Expected: BUILD FAILURE — `value of type 'SubscriptionService' has no member 'subscribeToFeedURL'`.

- [ ] **Step 3: Implement**

In `Onda/Services/SubscriptionService.swift`:

1. Replace the body of `subscribe(to:)` so its tail goes through a shared helper, and add the two new methods after it:

```swift
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
        try await activateSubscription(podcast)
        return podcast
    }

    /// Fetches and parses a feed without persisting anything — the AddFeedSheet preview step.
    func previewFeed(_ url: URL) async throws -> ParsedFeed {
        try await feeds.fetchFeed(url)
    }

    /// Subscribe to a feed directly by URL (private/paid tokenized feeds). Show metadata comes
    /// from the feed channel itself; nothing is persisted if the fetch fails.
    @discardableResult
    func subscribeToFeedURL(_ url: URL) async throws -> Podcast {
        let parsed = try await feeds.fetchFeed(url)   // validate before inserting anything
        let podcast = try existingPodcast(feedURL: url) ?? {
            let p = Podcast(feedURL: url, title: parsed.title, author: parsed.author,
                            artworkURL: parsed.artworkURL, category: parsed.category,
                            itunesId: nil, isPrivateFeed: true)
            modelContext.insert(p)
            return p
        }()
        try await activateSubscription(podcast)
        return podcast
    }

    /// Shared subscribe tail for both the iTunes and direct-URL paths: mark subscribed, ensure
    /// settings, pull episodes, and prime the newest episode for offline.
    private func activateSubscription(_ podcast: Podcast) async throws {
        podcast.isSubscribed = true
        if podcast.settings == nil {
            let s = ShowSettings.makeDefault(); s.podcast = podcast; podcast.settings = s
            modelContext.insert(s)
        }
        try await refreshEpisodes(for: podcast)
        try modelContext.save()
        // Grab the latest episode so a freshly-subscribed show has something ready offline.
        if let newest = podcast.episodes.max(by: { $0.publishDate < $1.publishDate }) {
            downloadEpisode?(newest)   // idempotent in DownloadManager
        }
    }
```

(The comment lines previously inside `subscribe(to:)`'s tail move with the code into `activateSubscription`.)

- [ ] **Step 4: Run the full SubscriptionServiceTests class**

Same command as Step 2. Expected: all tests pass, including the pre-existing ones (`test_subscribe_autoDownloadsNewestEpisode` etc. exercise the refactored tail).

- [ ] **Step 5: Commit**

```bash
git add Onda/Services/SubscriptionService.swift OndaTests/SubscriptionServiceTests.swift
git commit -m "feat: subscribe to private feeds directly by URL"
```

---

### Task 3: Exclude private shows from the taste profile

**Files:**
- Modify: `Onda/Recommendations/TasteProfile.swift`
- Test: `OndaTests/RecommendationPipelineTests.swift`

**Interfaces:**
- Consumes: `Podcast.isPrivateFeed` from Task 1.
- Produces: `TasteProfileBuilder.build` silently skips private podcasts — no signature change.

- [ ] **Step 1: Write the failing test**

Append to `RecommendationPipelineTests` (it already has a `ctx()` helper):

```swift
    func test_profile_excludesPrivateFeeds() throws {
        let ctx = try ctx()
        let priv = Podcast(feedURL: URL(string: "https://ex.com/p.xml?token=s3cret")!,
                           title: "Secret Members Show", author: "Patron Person",
                           artworkURL: nil, category: "TrueCrime", itunesId: nil,
                           isPrivateFeed: true)
        ctx.insert(priv)
        let ep = Episode(guid: "e", title: "Members Only Episode", publishDate: .now, duration: 10,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.played = true
        ep.podcast = priv; priv.episodes.append(ep); ctx.insert(ep)

        let profile = TasteProfileBuilder.build(subscriptions: [priv], clips: [], searchTerms: [])
        XCTAssertTrue(profile.isEmpty,
                      "private shows must contribute nothing — their terms feed iTunes search queries")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/RecommendationPipelineTests/test_profile_excludesPrivateFeeds
```
Expected: FAIL — `XCTAssertTrue failed` (profile contains the show's category/title terms).

- [ ] **Step 3: Implement the exclusion**

In `Onda/Recommendations/TasteProfile.swift`, change the subscription loop in `TasteProfileBuilder.build`:

```swift
        // Private feeds are excluded entirely: profile terms become iTunes search queries,
        // and a paid show's titles/topics shouldn't leave the device.
        for pod in subscriptions where !pod.isPrivateFeed {
```

(The rest of the loop body is unchanged.)

- [ ] **Step 4: Run the full RecommendationPipelineTests class**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/RecommendationPipelineTests
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Onda/Recommendations/TasteProfile.swift OndaTests/RecommendationPipelineTests.swift
git commit -m "feat: keep private feeds out of the taste profile"
```

---

### Task 4: AddFeedSheet UI, Discover entry point, Library badge

**Files:**
- Create: `Onda/Discover/AddFeedSheet.swift`
- Modify: `Onda/Shell/DiscoverView.swift` (search field row + sheet presentation)
- Modify: `Onda/Library/ShowCard.swift` (PRIVATE badge)

**Interfaces:**
- Consumes: `SubscriptionService.previewFeed(_:)`, `SubscriptionService.subscribeToFeedURL(_:)` (Task 2), `Podcast.isPrivateFeed` (Task 1), `ArtworkView(url:seed:)`, theme modifiers.
- Produces: `struct AddFeedSheet: View` presented from DiscoverView.

Note on clipboard: the spec says "pre-filled from the clipboard". Reading `UIPasteboard.general.url` on appear triggers the iOS "pasted from…" banner on every sheet open, so instead we check `UIPasteboard.general.hasURLs` (free, no banner) and show an explicit **Paste Link** button that fills the field on tap. Same convenience, no surprise banner.

- [ ] **Step 1: Create `Onda/Discover/AddFeedSheet.swift`**

```swift
//  AddFeedSheet.swift
//  Add a show by pasting its (typically private/paid, tokenized) RSS feed URL.
import SwiftUI

struct AddFeedSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var preview: ParsedFeed?
    @State private var previewURL: URL?
    @State private var loading = false
    @State private var errorText: String?
    @FocusState private var fieldFocused: Bool

    private var enteredURL: URL? {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add by URL").brutalHeader(size: 24).foregroundStyle(theme.color(.text))
                Text("Paste the RSS link from your paid membership (Patreon, Supercast, and similar). Private links stay on this device.")
                    .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))

                urlField
                if UIPasteboard.general.hasURLs && preview == nil {
                    Button {
                        if let pasted = UIPasteboard.general.url {
                            urlText = pasted.absoluteString
                            Task { await fetchPreview() }
                        }
                    } label: {
                        Label("Paste Link", systemImage: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }

                if let errorText {
                    Text(errorText).font(.system(size: 13))
                        .foregroundStyle(theme.color(.accent))
                }

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.color(.accent))
                        Text("Loading feed…").font(.system(size: 13))
                            .foregroundStyle(theme.color(.textTertiary))
                    }.frame(maxWidth: .infinity).padding(.top, 8)
                } else if let preview {
                    previewCard(preview)
                } else {
                    fetchButton
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .onAppear { fieldFocused = true }
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(theme.color(.textTertiary))
            TextField("https://…", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($fieldFocused)
                .onSubmit { Task { await fetchPreview() } }
                .accessibilityLabel("Feed URL")
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
        .onChange(of: urlText) { _, _ in preview = nil; errorText = nil }
    }

    private var fetchButton: some View {
        Button { Task { await fetchPreview() } } label: {
            Text("Fetch Feed").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(enteredURL == nil ? theme.color(.textTertiary) : theme.color(.accent))
                .brutalBorder(width: 2.5)
        }
        .buttonStyle(.plain)
        .disabled(enteredURL == nil)
        .accessibilityLabel("Fetch feed")
    }

    private func previewCard(_ feed: ParsedFeed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(url: feed.artworkURL, seed: feed.title)
                    .frame(width: 72, height: 72).hardShadow(offset: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.title).brutalHeader(size: 15).foregroundStyle(theme.color(.text))
                        .lineLimit(2)
                    Text(feed.author).font(.system(size: 12.5))
                        .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                    Text("\(feed.episodes.count) episodes · \(feed.category)")
                        .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                }
                Spacer(minLength: 0)
            }
            Button { Task { await subscribe() } } label: {
                Text("Subscribe").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(theme.color(.accent)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subscribe to \(feed.title)")
        }
        .padding(14)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    private func fetchPreview() async {
        guard let url = enteredURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            preview = try await subscriptions.previewFeed(url)
            previewURL = url
            fieldFocused = false
        } catch {
            preview = nil
            errorText = "Couldn't load this feed — check that the URL is correct and your membership is active."
        }
    }

    private func subscribe() async {
        guard let url = previewURL else { return }
        loading = true; errorText = nil; defer { loading = false }
        do {
            _ = try await subscriptions.subscribeToFeedURL(url)
            dismiss()
        } catch {
            errorText = "Couldn't subscribe — check your connection and try again."
        }
    }
}
```

- [ ] **Step 2: Wire it into DiscoverView**

In `Onda/Shell/DiscoverView.swift`:

Add state next to the other `@State` vars:

```swift
    @State private var showAddFeed = false
```

Replace the `searchField` computed property's outer layout so the add button sits beside it — change `browseTab`'s first line from `searchField` to `searchRow`, and add:

```swift
    private var searchRow: some View {
        HStack(spacing: 10) {
            searchField
            Button { showAddFeed = true } label: {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.color(.textSecondary))
                    .frame(width: 48, height: 48)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add show by feed URL")
            .accessibilityHint("For private or paid podcast feeds")
        }
    }
```

Add the sheet to `body`, after `.scrollDismissesKeyboard(.immediately)`:

```swift
        .sheet(isPresented: $showAddFeed) {
            AddFeedSheet().presentationDetents([.medium, .large])
        }
```

- [ ] **Step 3: PRIVATE badge on ShowCard**

In `Onda/Library/ShowCard.swift`, replace the title `Text` line with a badge-aware row:

```swift
            HStack(spacing: 6) {
                Text(podcast.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(2)
                if podcast.isPrivateFeed {
                    Text("PRIVATE").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(theme.color(.bg))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.color(.textSecondary))
                        .accessibilityLabel("Private feed")
                }
            }
```

- [ ] **Step 4: Regenerate the project and build**

```sh
xcodegen generate
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Lint**

```sh
swiftlint lint
```
Expected: no new violations in the touched files.

- [ ] **Step 6: Run the full test suite**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests
```
Expected: all unit tests pass.

- [ ] **Step 7: Commit**

```bash
git add Onda/Discover/AddFeedSheet.swift Onda/Shell/DiscoverView.swift Onda/Library/ShowCard.swift Onda.xcodeproj
git commit -m "feat: add-by-URL sheet in Discover + private badge in Library"
```
