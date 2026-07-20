# Hide Podcast Categories from Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user hide whole podcast categories (e.g. "True Crime") so they never appear in Discover's suggestion surfaces — Trending, category browse chips, Shake, and For You recommendations — while typed search stays unaffected.

**Architecture:** A new `HiddenCategories` store (`@MainActor @Observable`, `UserDefaults`-backed) mirrors the existing `HiddenShows`/`DismissedShows` pattern. It owns Apple's canonical 19-category list and an `isHidden` check on `PodcastDTO.primaryGenreName`. It's wired into every suggestion-producing code path (`DiscoverView`'s trending/shake/chip logic, `DiscoverSuggestions.shakeSuggestions`, `CandidateRetriever.retrieve`, `RecommendationService.charts`) the same way `DismissedShows`/subscribed-feed exclusion already is. A new `HiddenCategoriesView` settings screen is the picker itself (unlike `HiddenPodcastsView`, there's no swipe/context-menu entry point elsewhere).

**Tech Stack:** SwiftUI, SwiftData, Swift 6 (strict concurrency), XcodeGen, XCTest.

## Global Constraints

- Swift 6.0 / strict concurrency: `Searching: Sendable`, and `DiscoverSuggestions.shakeSuggestions` is a non-`@MainActor` free function — pass hidden-category exclusion into it as a plain `Set<String>` value (Sendable), never as a closure capturing an `@Observable @MainActor` class. `CandidateRetriever`/`RecommendationService` are both `@MainActor`, so closures (matching the existing `isDismissed` pattern) are safe there.
- Follow the MV pattern already in place: `@Observable` model/service classes, no ViewModel layer; new services are injected via `.environment(...)` in `Onda/OndaApp.swift`.
- Theme conventions: `.scaledFont(size, weight:)`, `.brutalHeader(size:)`, `theme.color(_:)`, `BrutalCard { }`, `.brutalBorder(width:)` — no raw `.font(.system(size:))` or hardcoded colors.
- After adding any new `.swift` file, run `xcodegen generate` (folder-based `sources:` in `project.yml` — file is auto-discovered, but the Xcode project file itself needs regenerating).
- Canonical category list (verbatim from spec, alphabetical, 19 entries): `Arts, Business, Comedy, Education, Fiction, Government, Health & Fitness, History, Kids & Family, Leisure, Music, News, Religion & Spirituality, Science, Society & Culture, Sports, Technology, True Crime, TV & Film`.
- Hidden categories filter Trending, category chips, Shake, and For You (including cold-start charts) — **never** typed search results, and never a show the user is already subscribed to.
- This Mac runs multiple concurrent Claude/xcodebuild sessions against shared simulators, which causes phantom test failures ("app is not running", stalls, cross-branch installs). Every verification command in this plan uses a **dedicated simulator device** (`onda-hide-categories-test`) and an **isolated DerivedData path**, never a `booted` device. Also avoid running the full test suite — `OndaTests/SpeechEngineReproTests` hangs ~35 min without a pre-seeded Speech TCC record, and it's irrelevant to this feature — always scope runs with `-only-testing:`.

**One-time setup — run before Task 1's first test:**

```bash
xcrun simctl create onda-hide-categories-test \
  "$(xcrun simctl list devicetypes | grep "iPhone 17 (" | head -1 | sed -E 's/.*\(([^()]+)\)\s*$/\1/')" \
  2>/dev/null || echo "device already exists, continuing"
SIM_UDID=$(xcrun simctl list devices | grep onda-hide-categories-test | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
echo "SIM_UDID=$SIM_UDID"
```

Every test command below re-derives `SIM_UDID` the same way (the device persists across tasks/sessions once created) and uses `-derivedDataPath /tmp/onda-hide-categories-dd`.

---

### Task 1: `HiddenCategories` store + app-wide wiring

**Files:**
- Create: `Onda/Discover/HiddenCategories.swift`
- Test: `OndaTests/HiddenCategoriesTests.swift`
- Modify: `Onda/OndaApp.swift`

**Interfaces:**
- Produces: `HiddenCategories` — `@MainActor @Observable final class`, `init(defaults: UserDefaults = .standard)`, `static let all: [String]` (19 canonical categories), `private(set) var hidden: Set<String>`, `func isHidden(category: String) -> Bool`, `func isHidden(_ dto: PodcastDTO) -> Bool`, `func toggle(_ category: String)`. Available app-wide via `@Environment(HiddenCategories.self)`.

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/HiddenCategoriesTests.swift`:

```swift
//  HiddenCategoriesTests.swift
import XCTest
@testable import Onda

@MainActor
final class HiddenCategoriesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "HiddenCategoriesTests")
        defaults.removePersistentDomain(forName: "HiddenCategoriesTests")
    }

    private func dto(_ name: String, genre: String?) -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: name, artistName: "Artist",
                   feedUrl: URL(string: "https://ex.com/f.xml"), artworkUrl600: nil,
                   primaryGenreName: genre)
    }

    func test_all_isCanonicalAppleCategoryList() {
        XCTAssertEqual(HiddenCategories.all.count, 19)
        XCTAssertEqual(Set(HiddenCategories.all).count, 19, "no duplicates")
        XCTAssertTrue(HiddenCategories.all.contains("True Crime"))
        XCTAssertTrue(HiddenCategories.all.contains("Health & Fitness"))
    }

    func test_toggle_hidesAndUnhides_andPersistsAcrossInstances() {
        let store = HiddenCategories(defaults: defaults)
        XCTAssertFalse(store.isHidden(category: "True Crime"))

        store.toggle("True Crime")
        XCTAssertTrue(store.isHidden(category: "True Crime"))

        let reloaded = HiddenCategories(defaults: defaults)
        XCTAssertTrue(reloaded.isHidden(category: "True Crime"), "hidden set survives relaunch")

        store.toggle("True Crime")
        XCTAssertFalse(store.isHidden(category: "True Crime"))
    }

    func test_isHidden_dto_matchesOnPrimaryGenreName() {
        let store = HiddenCategories(defaults: defaults)
        let show = dto("Serial Killers Weekly", genre: "True Crime")
        let other = dto("Tech Talk", genre: "Technology")
        XCTAssertFalse(store.isHidden(show))

        store.toggle("True Crime")
        XCTAssertTrue(store.isHidden(show))
        XCTAssertFalse(store.isHidden(other))
    }

    func test_isHidden_dto_withNilGenre_isNeverHidden() {
        let store = HiddenCategories(defaults: defaults)
        store.toggle("True Crime")
        let noGenre = dto("Mystery Show", genre: nil)
        XCTAssertFalse(store.isHidden(noGenre))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/HiddenCategoriesTests
```

Expected: FAIL — `cannot find 'HiddenCategories' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Implement `HiddenCategories`**

Create `Onda/Discover/HiddenCategories.swift`:

```swift
//  HiddenCategories.swift
//  User-curated "never suggest this genre" list: hidden categories are filtered out of
//  Trending, category browsing, Shake, and For You recommendations. Search results are never
//  filtered — an explicit search is an explicit ask. Managed entirely from the Hidden
//  Categories settings screen (no swipe/context entry point elsewhere, unlike HiddenShows).
import Foundation

@MainActor
@Observable
final class HiddenCategories {
    static let key = "hiddenCategoriesList"

    /// Apple's top-level podcast categories — the picker's full list, so a category can be
    /// hidden pre-emptively even before it's ever shown up in the user's results.
    static let all = [
        "Arts", "Business", "Comedy", "Education", "Fiction", "Government", "Health & Fitness",
        "History", "Kids & Family", "Leisure", "Music", "News", "Religion & Spirituality",
        "Science", "Society & Culture", "Sports", "Technology", "True Crime", "TV & Film"
    ]

    private let defaults: UserDefaults
    private(set) var hidden: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isHidden(category: String) -> Bool { hidden.contains(category) }

    func isHidden(_ dto: PodcastDTO) -> Bool {
        dto.primaryGenreName.map(isHidden(category:)) ?? false
    }

    func toggle(_ category: String) {
        if hidden.contains(category) { hidden.remove(category) } else { hidden.insert(category) }
        persist()
    }

    private func persist() {
        defaults.set(Array(hidden), forKey: Self.key)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/HiddenCategoriesTests
```

Expected: PASS (4 tests).

- [ ] **Step 5: Wire into `OndaApp.swift`**

In `Onda/OndaApp.swift`, find:

```swift
    @State private var hiddenShows = HiddenShows()
```

Replace with:

```swift
    @State private var hiddenShows = HiddenShows()
    @State private var hiddenCategories = HiddenCategories()
```

Then find, in `body`:

```swift
                .environment(hiddenShows)
                .environment(refresh)
```

Replace with:

```swift
                .environment(hiddenShows)
                .environment(hiddenCategories)
                .environment(refresh)
```

- [ ] **Step 6: Build to confirm no compile errors**

```bash
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Onda/Discover/HiddenCategories.swift OndaTests/HiddenCategoriesTests.swift \
  Onda/OndaApp.swift Onda.xcodeproj
git commit -m "feat: add HiddenCategories store for hiding podcast categories"
```

---

### Task 2: Hidden Categories settings screen

**Files:**
- Create: `Onda/Profile/HiddenCategoriesView.swift`
- Modify: `Onda/Shell/ProfileView.swift`

**Interfaces:**
- Consumes: `HiddenCategories.all`, `HiddenCategories.isHidden(category:)`, `HiddenCategories.toggle(_:)` (Task 1).
- Produces: `HiddenCategoriesView` — a `View`, reachable from Profile.

No unit test for this step — it's a pure SwiftUI screen with no logic beyond calling already-tested `HiddenCategories` methods, matching the sibling `HiddenPodcastsView` (also untested at the unit level). Verified by build + the end-to-end simulator check in Task 7.

- [ ] **Step 1: Create the settings screen**

Create `Onda/Profile/HiddenCategoriesView.swift`:

```swift
//  HiddenCategoriesView.swift
//  Settings screen for hiding whole podcast categories from suggestion surfaces (Trending,
//  category browsing, Shake, For You). Doubles as its own picker — unlike HiddenPodcastsView,
//  there's no swipe/context-menu entry point elsewhere to hide a category from.
import SwiftUI

struct HiddenCategoriesView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(HiddenCategories.self) private var hiddenCategories

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hidden from Trending, category browsing, Shake, and For You. "
                     + "Search results aren't affected.")
                    .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                ForEach(HiddenCategories.all, id: \.self) { category in
                    categoryRow(category)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color(.bg))
        .navigationTitle("Hidden Categories")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryRow(_ category: String) -> some View {
        let isHidden = hiddenCategories.isHidden(category: category)
        return Button { hiddenCategories.toggle(category) } label: {
            BrutalCard {
                HStack {
                    Text(category).scaledFont(15, weight: .semibold)
                        .foregroundStyle(theme.color(.text))
                    Spacer()
                    if isHidden {
                        Image(systemName: "checkmark").scaledFont(14, weight: .bold)
                            .foregroundStyle(theme.color(.accentStrong))
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category)
        .accessibilityAddTraits(isHidden ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isHidden ? "Hidden. Double-tap to show again."
                                    : "Double-tap to hide from suggestions.")
    }
}
```

- [ ] **Step 2: Link it from Profile**

In `Onda/Shell/ProfileView.swift`, find:

```swift
                    BrutalCard { navRow("Hidden Podcasts", destination: HiddenPodcastsView()) }
                    BrutalCard { navRow("Downloads & Storage", destination: DownloadsStorageView()) }
```

Replace with:

```swift
                    BrutalCard { navRow("Hidden Podcasts", destination: HiddenPodcastsView()) }
                    BrutalCard { navRow("Hidden Categories", destination: HiddenCategoriesView()) }
                    BrutalCard { navRow("Downloads & Storage", destination: DownloadsStorageView()) }
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
xcodegen generate
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Onda/Profile/HiddenCategoriesView.swift Onda/Shell/ProfileView.swift Onda.xcodeproj
git commit -m "feat: add Hidden Categories settings screen"
```

---

### Task 3: `DiscoverSuggestions.shakeSuggestions` category filtering

**Files:**
- Modify: `Onda/Discover/DiscoverSuggestions.swift`
- Test: `OndaTests/DiscoverSuggestionsTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–2 directly (this is pure/testable in isolation — a `Set<String>` is all it needs).
- Produces: `shakeSuggestions(..., hiddenCategories: Set<String> = [], ...)` — new parameter later consumed by `DiscoverView` (Task 6).

- [ ] **Step 1: Write the failing tests**

In `OndaTests/DiscoverSuggestionsTests.swift`, find the `dto` helper:

```swift
private func dto(_ name: String, feed: String?, id: Int? = nil) -> PodcastDTO {
    PodcastDTO(collectionId: id, collectionName: name, artistName: "Artist",
               feedUrl: feed.flatMap { URL(string: $0) }, artworkUrl600: nil,
               primaryGenreName: nil)
}
```

Replace with (adds an optional `genre` param, default-compatible with every existing call):

```swift
private func dto(_ name: String, feed: String?, id: Int? = nil, genre: String? = nil) -> PodcastDTO {
    PodcastDTO(collectionId: id, collectionName: name, artistName: "Artist",
               feedUrl: feed.flatMap { URL(string: $0) }, artworkUrl600: nil,
               primaryGenreName: genre)
}
```

Then, at the end of the `DiscoverSuggestionsTests` class (just before the final closing `}`), add:

```swift

    func test_filtersHiddenCategoryShows() async {
        let client = StubSearch(byTerm: [
            "Technology": [dto("Tech Show", feed: "https://ex.com/tech.xml", genre: "Technology"),
                            dto("Crime Show", feed: "https://ex.com/crime.xml", genre: "True Crime")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], hiddenCategories: ["True Crime"], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Tech Show"])
    }

    func test_defaultHiddenCategories_filtersNothing() async {
        let client = StubSearch(byTerm: [
            "Technology": [dto("Crime Show", feed: "https://ex.com/crime.xml", genre: "True Crime")]
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Crime Show"])
    }
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/DiscoverSuggestionsTests
```

Expected: FAIL — `test_filtersHiddenCategoryShows` fails to compile (`extra argument 'hiddenCategories' in call`), since `shakeSuggestions` doesn't accept that parameter yet.

- [ ] **Step 3: Implement the filter**

In `Onda/Discover/DiscoverSuggestions.swift`, find the doc comment + signature:

```swift
/// Builds a random set of podcast suggestions for the shake gesture.
///
/// Draws up to two distinct categories from `followedCategories` (or `fallbackCategories`
/// when the user follows nothing), searches each, removes already-followed shows, de-dupes
/// and shuffles, then caps at `limit`. Randomness is injected via `rng` so the pipeline is
/// deterministic under test; a search that throws is skipped rather than fatal.
///
/// Callers must pass already-distinct category arrays.
func shakeSuggestions(
    followedCategories: [String],
    fallbackCategories: [String],
    subscribedFeeds: Set<URL>,
    limit: Int = 20,
    using client: any Searching,
    rng: inout some RandomNumberGenerator
) async -> ShakeSuggestions {
```

Replace with:

```swift
/// Builds a random set of podcast suggestions for the shake gesture.
///
/// Draws up to two distinct categories from `followedCategories` (or `fallbackCategories`
/// when the user follows nothing), searches each, removes already-followed shows, de-dupes
/// and shuffles, then caps at `limit`. Randomness is injected via `rng` so the pipeline is
/// deterministic under test; a search that throws is skipped rather than fatal. `hiddenCategories`
/// drops any returned show whose genre is hidden, even if it arrived via a non-hidden query term.
///
/// Callers must pass already-distinct category arrays. `hiddenCategories` is a plain `Set<String>`
/// rather than a closure — this function runs off the main actor, so it can't safely capture an
/// `@Observable @MainActor` store.
func shakeSuggestions(
    followedCategories: [String],
    fallbackCategories: [String],
    subscribedFeeds: Set<URL>,
    hiddenCategories: Set<String> = [],
    limit: Int = 20,
    using client: any Searching,
    rng: inout some RandomNumberGenerator
) async -> ShakeSuggestions {
```

Then find the dedup loop:

```swift
    var seen = Set<String>()
    var deduped: [PodcastDTO] = []
    for dto in merged {
        if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
        let key = dto.feedUrl?.absoluteString
            ?? dto.collectionId.map(String.init)
            ?? dto.collectionName
        if seen.insert(key).inserted { deduped.append(dto) }
    }
```

Replace with:

```swift
    var seen = Set<String>()
    var deduped: [PodcastDTO] = []
    for dto in merged {
        if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
        if let genre = dto.primaryGenreName, hiddenCategories.contains(genre) { continue }
        let key = dto.feedUrl?.absoluteString
            ?? dto.collectionId.map(String.init)
            ?? dto.collectionName
        if seen.insert(key).inserted { deduped.append(dto) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/DiscoverSuggestionsTests
```

Expected: PASS (8 tests — 6 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Onda/Discover/DiscoverSuggestions.swift OndaTests/DiscoverSuggestionsTests.swift
git commit -m "feat: filter hidden categories out of shake suggestions"
```

---

### Task 4: `CandidateRetriever.retrieve` category filtering

**Files:**
- Modify: `Onda/Recommendations/CandidateRetriever.swift`
- Test: `OndaTests/RecommendationPipelineTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–3 directly (the closure param is generic; `RecommendationService` supplies the real `HiddenCategories`-backed closure in Task 5).
- Produces: `CandidateRetriever.retrieve(..., isCategoryHidden: (PodcastDTO) -> Bool = { _ in false }, ...)` — new parameter, alongside the existing `isDismissed`. Defaulted to a no-op so this task stays independently buildable; `RecommendationService.refresh`'s call site (Task 5) still passes the real closure explicitly to actually wire the filtering.

- [ ] **Step 1: Write the failing test**

In `OndaTests/RecommendationPipelineTests.swift`, find:

```swift
    func test_retriever_dropsSubscribedAndDismissed() async {
        let subscribed = dto("Sub", feed: "https://sub.com/f.xml")
        let dismissed = dto("Bad", feed: "https://bad.com/f.xml")
        let good = dto("Good", feed: "https://good.com/f.xml")
        let client = StubSearch(byTerm: ["coffee": [subscribed, dismissed, good]])
        var profile = TasteProfile(); profile.terms.add(text: "coffee", weight: 1)
        let retriever = CandidateRetriever(client: client)
        let pool = await retriever.retrieve(
            profile: profile, followedCategories: [],
            subscribedFeeds: [URL(string: "https://sub.com/f.xml")!],
            isDismissed: { $0.feedUrl?.absoluteString == "https://bad.com/f.xml" })
        XCTAssertEqual(pool.map(\.collectionName), ["Good"])
    }
```

Leave `test_retriever_dropsSubscribedAndDismissed` untouched (the new parameter defaults to a no-op, so its existing call still compiles and passes). Add a new test right after it:

```swift
    func test_retriever_dropsHiddenCategoryShows() async {
        let hidden = dto("Crime Show", feed: "https://crime.com/f.xml", genre: "True Crime")
        let good = dto("Good Show", feed: "https://good.com/f.xml", genre: "Technology")
        let client = StubSearch(byTerm: ["coffee": [hidden, good]])
        var profile = TasteProfile(); profile.terms.add(text: "coffee", weight: 1)
        let retriever = CandidateRetriever(client: client)
        let pool = await retriever.retrieve(
            profile: profile, followedCategories: [], subscribedFeeds: [],
            isDismissed: { _ in false },
            isCategoryHidden: { $0.primaryGenreName == "True Crime" })
        XCTAssertEqual(pool.map(\.collectionName), ["Good Show"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/RecommendationPipelineTests
```

Expected: FAIL to compile — `extra argument 'isCategoryHidden' in call`.

- [ ] **Step 3: Implement the filter**

In `Onda/Recommendations/CandidateRetriever.swift`, find:

```swift
    func retrieve(profile: TasteProfile, followedCategories: [String],
                  subscribedFeeds: Set<URL>, isDismissed: (PodcastDTO) -> Bool,
                  limit: Int = 60) async -> [PodcastDTO] {
        let queries = Self.queries(profile: profile, followedCategories: followedCategories)
        var merged: [PodcastDTO] = []
        for query in queries {
            if let found = try? await client.search(term: query) { merged.append(contentsOf: found) }
        }

        var seen = Set<String>()
        var pool: [PodcastDTO] = []
        for dto in merged {
            if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
            if isDismissed(dto) { continue }
            let key = dto.feedUrl?.absoluteString
                ?? dto.collectionId.map(String.init) ?? dto.collectionName
            if seen.insert(key).inserted { pool.append(dto) }
            if pool.count >= limit { break }
        }
        return pool
    }
```

Replace with:

```swift
    func retrieve(profile: TasteProfile, followedCategories: [String],
                  subscribedFeeds: Set<URL>, isDismissed: (PodcastDTO) -> Bool,
                  isCategoryHidden: (PodcastDTO) -> Bool = { _ in false },
                  limit: Int = 60) async -> [PodcastDTO] {
        let queries = Self.queries(profile: profile, followedCategories: followedCategories)
        var merged: [PodcastDTO] = []
        for query in queries {
            if let found = try? await client.search(term: query) { merged.append(contentsOf: found) }
        }

        var seen = Set<String>()
        var pool: [PodcastDTO] = []
        for dto in merged {
            if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
            if isDismissed(dto) { continue }
            if isCategoryHidden(dto) { continue }
            let key = dto.feedUrl?.absoluteString
                ?? dto.collectionId.map(String.init) ?? dto.collectionName
            if seen.insert(key).inserted { pool.append(dto) }
            if pool.count >= limit { break }
        }
        return pool
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/RecommendationPipelineTests
```

Expected: PASS (all tests in the class, including the new `test_retriever_dropsHiddenCategoryShows`). Because `isCategoryHidden` defaults to a no-op, every other call site (including `RecommendationService.refresh`, unchanged until Task 5) keeps compiling and behaving exactly as before.

- [ ] **Step 5: Commit**

```bash
git add Onda/Recommendations/CandidateRetriever.swift OndaTests/RecommendationPipelineTests.swift
git commit -m "feat: add category-hidden exclusion to CandidateRetriever"
```

---

### Task 5: `RecommendationService` wiring + cold-start chart filtering

**Files:**
- Modify: `Onda/Recommendations/RecommendationService.swift`
- Modify: `Onda/OndaApp.swift`
- Test: `OndaTests/RecommendationPipelineTests.swift`

**Interfaces:**
- Consumes: `HiddenCategories` (Task 1), `CandidateRetriever.retrieve(..., isCategoryHidden:)` (Task 4).
- Produces: `RecommendationService.init(..., hiddenCategories: HiddenCategories? = nil, ...)`.

This task also switches `RecommendationService.refresh`'s call to `retriever.retrieve` from the Task 4 default (`{ _ in false }`) to the real `HiddenCategories`-backed closure, so category hiding actually takes effect for For You recommendations.

- [ ] **Step 1: Write the failing test**

In `OndaTests/RecommendationPipelineTests.swift`, find `test_service_coldStart_fallsBackToCharts` and add a new test directly after it:

```swift
    func test_service_coldStart_excludesHiddenCategoryFromCharts() async throws {
        let ctx = try ctx()
        let hiddenShow = dto("Crime Show", feed: "https://crime.com/f.xml", genre: "True Crime")
        let goodShow = dto("Top Show", feed: "https://top.com/f.xml", genre: "News")
        let client = StubSearch(chartIds: [1, 2], chartLookup: [hiddenShow, goodShow])
        let feeds = StubFeeds(byURL: [
            URL(string: "https://crime.com/f.xml")!: feed("Crime Show", episodes: [("Ep", "murder")]),
            URL(string: "https://top.com/f.xml")!: feed("Top Show", episodes: [("Ep", "news of the day")])
        ])
        let hiddenCategories = HiddenCategories(defaults: freshDefaults())
        hiddenCategories.toggle("True Crime")
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds,
                                        embedding: nil, searchLog: SearchTermLog(defaults: freshDefaults()),
                                        dismissed: DismissedShows(defaults: freshDefaults()),
                                        hiddenCategories: hiddenCategories)
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.map(\.dto.collectionName), ["Top Show"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/RecommendationPipelineTests
```

Expected: FAIL to compile — `RecommendationService.init` doesn't accept a `hiddenCategories:` argument yet.

- [ ] **Step 3: Wire `HiddenCategories` into `RecommendationService`**

In `Onda/Recommendations/RecommendationService.swift`, find:

```swift
    private let dismissedStore: DismissedShows
    private let now: () -> Date
```

Replace with:

```swift
    private let dismissedStore: DismissedShows
    private let hiddenCategoriesStore: HiddenCategories
    private let now: () -> Date
```

Find:

```swift
    init(modelContext: ModelContext, client: Searching, feeds: FeedFetching,
         embedding: WordEmbedding? = AppleWordEmbedding(),
         searchLog: SearchTermLog? = nil, dismissed: DismissedShows? = nil,
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.client = client
        self.retriever = CandidateRetriever(client: client)
        self.reranker = CandidateReranker(feeds: feeds, embedding: embedding)
        self.searchLog = searchLog ?? SearchTermLog()
        self.dismissedStore = dismissed ?? DismissedShows()
        self.now = now
    }
```

Replace with:

```swift
    init(modelContext: ModelContext, client: Searching, feeds: FeedFetching,
         embedding: WordEmbedding? = AppleWordEmbedding(),
         searchLog: SearchTermLog? = nil, dismissed: DismissedShows? = nil,
         hiddenCategories: HiddenCategories? = nil,
         now: @escaping () -> Date = { .now }) {
        self.modelContext = modelContext
        self.client = client
        self.retriever = CandidateRetriever(client: client)
        self.reranker = CandidateReranker(feeds: feeds, embedding: embedding)
        self.searchLog = searchLog ?? SearchTermLog()
        self.dismissedStore = dismissed ?? DismissedShows()
        self.hiddenCategoriesStore = hiddenCategories ?? HiddenCategories()
        self.now = now
    }
```

Find, in `refresh(followedCategories:excluding:)`:

```swift
        var pool = await retriever.retrieve(
            profile: profile, followedCategories: followedCategories,
            subscribedFeeds: subscribedFeeds,
            isDismissed: { [dismissedStore] dto in
                dismissedStore.contains(dto) || dto.feedUrl.map(excluding.contains) ?? false
            })
```

Replace with:

```swift
        var pool = await retriever.retrieve(
            profile: profile, followedCategories: followedCategories,
            subscribedFeeds: subscribedFeeds,
            isDismissed: { [dismissedStore] dto in
                dismissedStore.contains(dto) || dto.feedUrl.map(excluding.contains) ?? false
            },
            isCategoryHidden: { [hiddenCategoriesStore] dto in hiddenCategoriesStore.isHidden(dto) })
```

Find `charts(excluding:existing:)`:

```swift
    private func charts(excluding subscribedFeeds: Set<URL>, existing: [PodcastDTO]) async -> [PodcastDTO] {
        guard let ids = try? await client.topChartIds(limit: 25),
              let charts = try? await client.lookup(ids: Array(ids.prefix(20))) else { return [] }
        let have = Set(existing.compactMap { $0.feedUrl?.absoluteString })
        return charts.filter { dto in
            guard let feed = dto.feedUrl else { return false }
            return !subscribedFeeds.contains(feed) && !have.contains(feed.absoluteString)
                && !dismissedStore.contains(dto)
        }
    }
```

Replace with:

```swift
    private func charts(excluding subscribedFeeds: Set<URL>, existing: [PodcastDTO]) async -> [PodcastDTO] {
        guard let ids = try? await client.topChartIds(limit: 25),
              let charts = try? await client.lookup(ids: Array(ids.prefix(20))) else { return [] }
        let have = Set(existing.compactMap { $0.feedUrl?.absoluteString })
        return charts.filter { dto in
            guard let feed = dto.feedUrl else { return false }
            return !subscribedFeeds.contains(feed) && !have.contains(feed.absoluteString)
                && !dismissedStore.contains(dto) && !hiddenCategoriesStore.isHidden(dto)
        }
    }
```

- [ ] **Step 4: Wire the shared instance in `OndaApp.swift`**

The RecommendationService needs the *same* `HiddenCategories` instance that's injected into the environment, so a toggle in Settings is immediately reflected in recommendations. In `Onda/OndaApp.swift`, find:

```swift
    @State private var hiddenShows = HiddenShows()
    @State private var hiddenCategories = HiddenCategories()
```

Replace with:

```swift
    @State private var hiddenShows = HiddenShows()
    @State private var hiddenCategories: HiddenCategories
```

Then find:

```swift
            _recommendations = State(initialValue: RecommendationService(
                modelContext: c.mainContext, client: ITunesSearchClient(), feeds: RSSFeedClient()))
```

Replace with:

```swift
            let hiddenCats = HiddenCategories()
            _hiddenCategories = State(initialValue: hiddenCats)
            _recommendations = State(initialValue: RecommendationService(
                modelContext: c.mainContext, client: ITunesSearchClient(), feeds: RSSFeedClient(),
                hiddenCategories: hiddenCats))
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -only-testing:OndaTests/RecommendationPipelineTests
```

Expected: PASS (all tests in the class, including the new one).

- [ ] **Step 6: Build to confirm `OndaApp.swift` compiles**

```bash
xcodegen generate
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Onda/Recommendations/RecommendationService.swift Onda/OndaApp.swift \
  OndaTests/RecommendationPipelineTests.swift
git commit -m "feat: exclude hidden categories from For You recommendations and cold-start charts"
```

---

### Task 6: `DiscoverView` integration — chips, trending/shake filtering, followed-categories seeding

**Files:**
- Modify: `Onda/Shell/DiscoverView.swift`

**Interfaces:**
- Consumes: `HiddenCategories` (Task 1, available via `@Environment`), `shakeSuggestions(..., hiddenCategories:)` (Task 3).
- Produces: nothing consumed by later tasks — this is the final integration point.

No new unit test — `DiscoverView`'s computed properties aren't unit-tested elsewhere in this codebase either (its logic delegates to already-tested `HiddenCategories`/`shakeSuggestions`). Verified by build + Task 7's simulator walkthrough.

- [ ] **Step 1: Add the environment dependency**

In `Onda/Shell/DiscoverView.swift`, find:

```swift
    @Environment(HiddenShows.self) private var hidden
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]
```

Replace with:

```swift
    @Environment(HiddenShows.self) private var hidden
    @Environment(HiddenCategories.self) private var hiddenCategories
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]
```

- [ ] **Step 2: Filter the quick-filter chips and `followedCategories`**

Find:

```swift
    private let categories = ["Technology", "Comedy", "News", "Business", "Health", "Science"]
    private var subscribedFeeds: Set<URL> { Set(subs.map(\.feedURL)) }
    private var followedCategories: [String] {
        Array(Set(subs.map(\.category))).sorted()
    }
```

Replace with:

```swift
    private static let allChipCategories = ["Technology", "Comedy", "News", "Business",
                                             "Health & Fitness", "Science"]
    private var categories: [String] {
        Self.allChipCategories.filter { !hiddenCategories.isHidden(category: $0) }
    }
    private var subscribedFeeds: Set<URL> { Set(subs.map(\.feedURL)) }
    private var followedCategories: [String] {
        Array(Set(subs.map(\.category))).sorted()
            .filter { !hiddenCategories.isHidden(category: $0) }
    }
```

(Renaming `"Health"` → `"Health & Fitness"` matches the canonical genre name from `HiddenCategories.all` exactly — chip removal is a plain string match, no fuzzy matching required.)

- [ ] **Step 3: Filter trending/shake items in `listItems`**

Find:

```swift
    private var listItems: [PodcastDTO] {
        let items: [PodcastDTO]
        if let picks = shake?.picks { items = picks } else if !results.isEmpty {
            items = results
        } else if selectedCategory != nil {
            items = categoryResults
        } else {
            items = trending
        }
        return items.filter { !hidden.isHidden($0) }
    }
```

Replace with:

```swift
    private var listItems: [PodcastDTO] {
        let items: [PodcastDTO]
        var filterHiddenCategories = false
        if let picks = shake?.picks {
            items = picks; filterHiddenCategories = true
        } else if !results.isEmpty {
            items = results
        } else if selectedCategory != nil {
            items = categoryResults
        } else {
            items = trending; filterHiddenCategories = true
        }
        return items.filter { dto in
            !hidden.isHidden(dto) && (!filterHiddenCategories || !hiddenCategories.isHidden(dto))
        }
    }
```

(Typed search `results` and an explicit `categoryResults` chip pick are never category-filtered — only Trending and Shake, matching the design.)

- [ ] **Step 4: Pass hidden categories into the shake pipeline**

Find, in `runShake()`:

```swift
    func runShake() async {
        let followed = Array(Set(subs.map(\.category))).sorted()
        var rng = SystemRandomNumberGenerator()
        let result = await shakeSuggestions(
            followedCategories: followed,
            fallbackCategories: categories,
            subscribedFeeds: subscribedFeeds,
            using: clientBox.client,
            rng: &rng)
```

Replace with:

```swift
    func runShake() async {
        var rng = SystemRandomNumberGenerator()
        let result = await shakeSuggestions(
            followedCategories: followedCategories,
            fallbackCategories: categories,
            subscribedFeeds: subscribedFeeds,
            hiddenCategories: hiddenCategories.hidden,
            using: clientBox.client,
            rng: &rng)
```

(This also removes the duplicate re-computation of the followed-categories list — `followedCategories` now already applies the same hidden-category filter.)

- [ ] **Step 5: Build to confirm no compile errors**

```bash
xcodegen generate
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Run the full non-Speech unit test suite as a regression check**

```bash
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$SIM_UDID" \
  -derivedDataPath /tmp/onda-hide-categories-dd \
  -skip-testing:OndaTests/SpeechEngineReproTests
```

Expected: all tests PASS (no regressions in unrelated suites from the `DiscoverView`/`RecommendationService` signature changes).

- [ ] **Step 7: Commit**

```bash
git add Onda/Shell/DiscoverView.swift
git commit -m "feat: filter hidden categories from Discover chips, trending, and shake"
```

---

### Task 7: End-to-end simulator verification

**Files:** none (manual/scripted verification only).

- [ ] **Step 1: Launch and drive the app**

Use the `verify` skill (Build, launch, and drive Onda in the iOS Simulator) to confirm, on the dedicated `onda-hide-categories-test` simulator:
1. Profile → "Hidden Categories" opens the new screen listing all 19 categories.
2. Tapping "True Crime" shows a checkmark; the row's accessibility hint reads "Hidden. Double-tap to show again."
3. Back in Discover (Browse tab): if "Technology" or another chip category was hidden instead, confirm its chip is gone from the row. (True Crime isn't one of the 6 quick chips, so hide "Health & Fitness" or "Technology" to see chip removal directly; separately verify True Crime no longer appears in Trending after a pull-to-refresh, if a True Crime show happens to be trending that day — this is best-effort since Trending content is live.)
4. Switch to the "For You" tab and pull-to-refresh; recommendations should contain no hidden-category shows.
5. Type a search for "true crime" in Discover search — results should NOT be filtered (confirms search stays unaffected).
6. Un-hide the category from Settings; confirm the chip reappears.

- [ ] **Step 2: Report results**

Summarize pass/fail for each of the 6 checks above. If any fail, file it as a bug to investigate before considering the feature done — do not silently patch without understanding root cause.

---

## Self-Review Notes

- **Spec coverage:** Data & storage (Task 1) ✓. Filtering integration points — Trending/Shake/chips/followedCategories (Task 6), For You + cold-start charts (Task 5), shakeSuggestions (Task 3), CandidateRetriever (Task 4) ✓. Settings UI (Task 2) ✓. Testing — HiddenCategoriesTests (Task 1), DiscoverSuggestionsTests (Task 3), RecommendationPipelineTests (Tasks 4–5), chip-filtering coverage via HiddenCategories tests + Task 7 manual check (Task 2/6) ✓.
- **Placeholder scan:** no TBD/TODO; every step has complete code.
- **Type consistency:** `HiddenCategories.isHidden(category:)` / `isHidden(_:PodcastDTO)` / `toggle(_:)` / `hidden: Set<String>` are used identically across Tasks 2, 3, 5, 6. `shakeSuggestions(..., hiddenCategories: Set<String>)` and `CandidateRetriever.retrieve(..., isCategoryHidden: (PodcastDTO) -> Bool)` names match between their definition tasks (3, 4) and call-site tasks (6, 5).
