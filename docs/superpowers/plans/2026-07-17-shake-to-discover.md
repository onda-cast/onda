# Shake to Discover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the Discover tab, shaking the phone refreshes the show list in place with random podcast suggestions drawn from the categories of shows the user already follows.

**Architecture:** A pure, unit-tested async function (`shakeSuggestions`) builds the suggestion set from injected randomness and the existing `Searching` client. A small SwiftUI `.onShake` modifier (backed by a first-responder `UIViewControllerRepresentable`) reports the gesture. `DiscoverView` wires them together: it holds an optional shake state, swaps the list source when set, and shows a rotating header + "Back to Trending" chip.

**Tech Stack:** SwiftUI (iOS 17+), SwiftData, XcodeGen, XCTest. Uses the existing `Searching` protocol (`Onda/Networking/FeedFetching.swift`) and `PodcastDTO` (`Onda/Networking/ITunesSearchClient.swift`).

## Global Constraints

- iOS deployment target: **17.0** — `.sensoryFeedback` is available; do not import UIKit for haptics.
- New source files under `Onda/` and `OndaTests/` are picked up via XcodeGen folder references. **After creating any new file, run `xcodegen generate` before building/testing.**
- Follow the neo-brutalist theme helpers already used in `DiscoverView`: `.brutalHeader(size:)`, `.brutalBorder(width:)`, `theme.color(.text|.textTertiary|.textSecondary|.bgElevated)`.
- Timeline/feed-seconds rules do not apply here (no playback code).
- Rotating header titles, exact copy: `"Shaken for you"`, `"Look what rolled in"`, `"New podcasts drifting in"`.

---

### Task 1: `shakeSuggestions` core + unit tests

**Files:**
- Create: `Onda/Discover/DiscoverSuggestions.swift`
- Test: `OndaTests/DiscoverSuggestionsTests.swift`

**Interfaces:**
- Consumes: `Searching` (protocol, `Onda/Networking/FeedFetching.swift`), `PodcastDTO` (`Onda/Networking/ITunesSearchClient.swift`).
- Produces:
  - `struct ShakeSuggestions: Equatable { var picks: [PodcastDTO]; var categories: [String]; var usedFallback: Bool }`
  - `func shakeSuggestions(followedCategories: [String], fallbackCategories: [String], subscribedFeeds: Set<URL>, limit: Int = 20, using client: any Searching, rng: inout some RandomNumberGenerator) async -> ShakeSuggestions`
  - Callers must pass **already-distinct** category arrays.

- [ ] **Step 1: Write the failing tests**

Create `OndaTests/DiscoverSuggestionsTests.swift`:

```swift
//  DiscoverSuggestionsTests.swift
import XCTest
@testable import Onda

// Deterministic RNG (SplitMix64) so shuffles/picks are reproducible in tests.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct StubSearch: Searching {
    var byTerm: [String: [PodcastDTO]] = [:]
    var throwingTerms: Set<String> = []
    enum StubError: Error { case boom }
    func search(term: String) async throws -> [PodcastDTO] {
        if throwingTerms.contains(term) { throw StubError.boom }
        return byTerm[term] ?? []
    }
    func lookup(ids: [Int]) async throws -> [PodcastDTO] { [] }
    func topChartIds(limit: Int) async throws -> [Int] { [] }
}

private func dto(_ name: String, feed: String?, id: Int? = nil) -> PodcastDTO {
    PodcastDTO(collectionId: id, collectionName: name, artistName: "Artist",
               feedUrl: feed.flatMap { URL(string: $0) }, artworkUrl600: nil,
               primaryGenreName: nil)
}

@MainActor
final class DiscoverSuggestionsTests: XCTestCase {

    func test_usesFollowedCategories_whenPresent() async {
        let client = StubSearch(byTerm: [
            "Technology": [dto("Tech Show", feed: "https://ex.com/tech.xml")],
            "Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")],
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.categories, ["Technology"])
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Tech Show"])
    }

    func test_fallsBackToBuiltInCategories_whenNoFollows() async {
        let client = StubSearch(byTerm: [
            "Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")],
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: [], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.categories, ["Comedy"])
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Funny Show"])
    }

    func test_filtersAlreadyFollowedShows() async {
        let followedFeed = "https://ex.com/tech-a.xml"
        let client = StubSearch(byTerm: [
            "Technology": [dto("Tech A", feed: followedFeed),
                           dto("Tech B", feed: "https://ex.com/tech-b.xml")],
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [URL(string: followedFeed)!], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Tech B"])
    }

    func test_dedupesAcrossCategories() async {
        let shared = dto("Shared Show", feed: "https://ex.com/shared.xml")
        let client = StubSearch(byTerm: [
            "Technology": [shared],
            "Comedy": [shared, dto("Comedy Only", feed: "https://ex.com/co.xml")],
        ])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology", "Comedy"], fallbackCategories: ["News"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertEqual(result.picks.count, 2)
        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Shared Show", "Comedy Only"])
    }

    func test_capsResultsAtLimit() async {
        let many = (0..<30).map { dto("Show \($0)", feed: "https://ex.com/\($0).xml") }
        let client = StubSearch(byTerm: ["Technology": many])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology"], fallbackCategories: ["Comedy"],
            subscribedFeeds: [], limit: 20, using: client, rng: &rng)

        XCTAssertEqual(result.picks.count, 20)
    }

    func test_skipsThrowingCategory() async {
        let client = StubSearch(
            byTerm: ["Comedy": [dto("Funny Show", feed: "https://ex.com/comedy.xml")]],
            throwingTerms: ["Technology"])
        var rng = SeededRNG(seed: 1)
        let result = await shakeSuggestions(
            followedCategories: ["Technology", "Comedy"], fallbackCategories: ["News"],
            subscribedFeeds: [], using: client, rng: &rng)

        XCTAssertEqual(Set(result.picks.map(\.collectionName)), ["Funny Show"])
    }
}
```

- [ ] **Step 2: Regenerate the project so the new test file joins the target**

Run: `xcodegen generate`
Expected: `Created project at Onda.xcodeproj`

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/DiscoverSuggestionsTests
```
Expected: FAIL — compile error, `cannot find 'shakeSuggestions' in scope` / `cannot find 'ShakeSuggestions' in scope`.

- [ ] **Step 4: Write the minimal implementation**

Create `Onda/Discover/DiscoverSuggestions.swift`:

```swift
//  DiscoverSuggestions.swift
import Foundation

/// Result of a "shake to discover" pass: the shows to show, the categories they were
/// drawn from (for the header subtitle), and whether the built-in fallback list was used.
struct ShakeSuggestions: Equatable {
    var picks: [PodcastDTO]
    var categories: [String]
    var usedFallback: Bool
}

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
    let usedFallback = followedCategories.isEmpty
    let source = usedFallback ? fallbackCategories : followedCategories
    guard !source.isEmpty else {
        return ShakeSuggestions(picks: [], categories: [], usedFallback: usedFallback)
    }

    let chosen = Array(source.shuffled(using: &rng).prefix(2))

    var merged: [PodcastDTO] = []
    for category in chosen {
        if let found = try? await client.search(term: category) {
            merged.append(contentsOf: found)
        }
    }

    var seen = Set<String>()
    var deduped: [PodcastDTO] = []
    for dto in merged {
        if let feed = dto.feedUrl, subscribedFeeds.contains(feed) { continue }
        let key = dto.feedUrl?.absoluteString
            ?? dto.collectionId.map(String.init)
            ?? dto.collectionName
        if seen.insert(key).inserted { deduped.append(dto) }
    }

    let picks = Array(deduped.shuffled(using: &rng).prefix(limit))
    return ShakeSuggestions(picks: picks, categories: chosen, usedFallback: usedFallback)
}
```

- [ ] **Step 5: Regenerate and run the tests to verify they pass**

Run:
```sh
xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/DiscoverSuggestionsTests
```
Expected: PASS — 6 tests succeed.

- [ ] **Step 6: Commit**

```bash
git add Onda/Discover/DiscoverSuggestions.swift OndaTests/DiscoverSuggestionsTests.swift project.yml Onda.xcodeproj
git commit -m "feat: shakeSuggestions core for shake-to-discover"
```

---

### Task 2: `.onShake` gesture modifier

**Files:**
- Create: `Onda/Discover/ShakeDetector.swift`

**Interfaces:**
- Produces: `func onShake(perform action: @escaping () -> Void) -> some View` (a `View` extension).
- Consumes: nothing from other tasks.

Note: not unit-tested — device-motion delivery has no public XCTest/XCUITest hook. Verified by build here and manual test in Task 3.

- [ ] **Step 1: Write the implementation**

Create `Onda/Discover/ShakeDetector.swift`:

```swift
//  ShakeDetector.swift
import SwiftUI

/// Reports device-shake gestures to SwiftUI. Backed by a first-responder view controller
/// so it only observes shakes while its host view is on screen — which, because RootView
/// mounts one tab body at a time, means shakes are seen only on the tab that uses it.
private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
    }
}

extension View {
    /// Runs `action` when the device is shaken while this view is on screen.
    func onShake(perform action: @escaping () -> Void) -> some View {
        background(ShakeDetector(onShake: action).frame(width: 0, height: 0))
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run:
```sh
xcodegen generate && xcodebuild build -project Onda.xcodeproj -scheme Onda \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Onda/Discover/ShakeDetector.swift project.yml Onda.xcodeproj
git commit -m "feat: onShake gesture modifier"
```

---

### Task 3: Wire shake into `DiscoverView`

**Files:**
- Modify: `Onda/Shell/DiscoverView.swift`

**Interfaces:**
- Consumes: `shakeSuggestions(...)` / `ShakeSuggestions` (Task 1), `onShake(perform:)` (Task 2), existing `subs` `@Query`, `subscribedFeeds`, `categories`, `clientBox`, `TrendingRow`.
- Produces: no new public interface.

- [ ] **Step 1: Add shake state, titles, and the nested state struct**

In `DiscoverView`, add these members alongside the existing `@State` properties (after `@State private var loading = false`):

```swift
    @State private var shake: ShakeState?
    @State private var shakeCount = 0

    private static let shakeTitles = [
        "Shaken for you", "Look what rolled in", "New podcasts drifting in",
    ]

    private struct ShakeState {
        var picks: [PodcastDTO]
        var categories: [String]
        var usedFallback: Bool
        var title: String
    }
```

- [ ] **Step 2: Replace the list section (header + rows) to honor shake mode**

Replace this block in `body`:

```swift
                Text(results.isEmpty ? "Trending Today" : "Results")
                    .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))

                ForEach(results.isEmpty ? trending : results, id: \.collectionId) { dto in
                    TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                        Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: dto) }
                    }
                }
```

with:

```swift
                listHeader

                ForEach(listItems, id: \.collectionId) { dto in
                    TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                        Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: dto) }
                    }
                }
```

- [ ] **Step 3: Add `.onShake` and `.sensoryFeedback` to the `ScrollView`**

Add these modifiers to the `ScrollView` in `body`, right after the existing
`.onChange(of: query) { ... }` line:

```swift
        .onShake {
            shakeCount += 1
            Task { await runShake() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakeCount)
```

- [ ] **Step 4: Clear shake mode when the user starts a search**

Replace the existing `.onChange(of: query)` modifier:

```swift
        .onChange(of: query) { _, new in Task { await runSearch(new) } }
```

with:

```swift
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { shake = nil }
            Task { await runSearch(new) }
        }
```

- [ ] **Step 5: Add the computed list source, header view, and shake helpers**

Add these members to `DiscoverView` (e.g. after the `categoryChips` computed property):

```swift
    private var listItems: [PodcastDTO] {
        shake?.picks ?? (results.isEmpty ? trending : results)
    }

    @ViewBuilder private var listHeader: some View {
        if let shake {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(shake.title).brutalHeader(size: 13)
                        .foregroundStyle(theme.color(.textTertiary))
                    Spacer()
                    Button { withAnimation { self.shake = nil } } label: {
                        Text("Back to Trending")
                            .font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
                Text(subtitle(for: shake)).font(.system(size: 12))
                    .foregroundStyle(theme.color(.textTertiary))
            }
        } else {
            Text(results.isEmpty ? "Trending Today" : "Results")
                .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
        }
    }

    private func subtitle(for shake: ShakeState) -> String {
        let names = shake.categories
        if shake.usedFallback || names.isEmpty { return "A random mix by topic" }
        if names.count == 1 { return "Because you follow \(names[0])" }
        return "Because you follow \(names[0]) & \(names[1])"
    }

    private func runShake() async {
        let followed = Array(Set(subs.map(\.category))).sorted()
        var rng = SystemRandomNumberGenerator()
        let result = await shakeSuggestions(
            followedCategories: followed,
            fallbackCategories: categories,
            subscribedFeeds: subscribedFeeds,
            using: clientBox.client,
            rng: &rng)
        let title = Self.shakeTitles.randomElement() ?? "Shaken for you"
        withAnimation(.easeInOut) {
            shake = ShakeState(picks: result.picks, categories: result.categories,
                               usedFallback: result.usedFallback, title: title)
        }
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run:
```sh
xcodebuild build -project Onda.xcodeproj -scheme Onda \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Run the full unit-test suite (guard against regressions)**

Run:
```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests
```
Expected: PASS — all unit tests, including `DiscoverSuggestionsTests`, succeed.

- [ ] **Step 8: Lint**

Run: `swiftlint lint --quiet`
Expected: no violations in `Onda/Discover/DiscoverSuggestions.swift`, `Onda/Discover/ShakeDetector.swift`, or `Onda/Shell/DiscoverView.swift`.

- [ ] **Step 9: Manual verification (device or simulator)**

In the iOS Simulator: open the app → Discover tab → **Device ▸ Shake** (⌃⌘Z).
Expected: haptic (on device), the list refreshes to suggestions, the header shows one of
the three rotating titles with a "Because you follow …" (or "A random mix by topic")
subtitle, and a "Back to Trending" chip appears. Tapping the chip restores Trending;
shaking again reshuffles; typing in search clears shake mode.

- [ ] **Step 10: Commit**

```bash
git add Onda/Shell/DiscoverView.swift
git commit -m "feat: shake Discover to get suggestions by followed categories"
```

---

## Self-Review

**Spec coverage:**
- Shake refreshes list in place (full-refresh feel) → Task 3 Steps 2–3, 5 (`withAnimation`, `listItems`).
- 1–2 random categories from followed shows → Task 1 (`chosen = prefix(2)`), Task 3 (`runShake`).
- Fallback to built-in categories when no follows → Task 1 (`usedFallback`), Task 3 (passes `categories`).
- Search categories, de-dupe, drop followed, shuffle, cap ~20 → Task 1.
- Haptic → Task 3 Step 3 (`.sensoryFeedback`).
- Rotating header titles (3 exact strings) → Task 3 Steps 1, 5.
- Subtitle naming categories / fallback wording → Task 3 (`subtitle(for:)`).
- "Back to Trending" chip → Task 3 (`listHeader`).
- Typing search exits shake mode → Task 3 Step 4.
- Discover-only gating → Task 2 (first-responder scoping) + RootView `switch`.
- Failed search skipped, empty state graceful → Task 1 (`try?`), Task 3 (empty `listItems` renders no rows).
- Unit tests for the core; gesture not UI-tested → Task 1 tests; Task 3 Step 9 manual.

**Placeholder scan:** none — every code step contains full code.

**Type consistency:** `ShakeSuggestions`/`shakeSuggestions` signature identical across Task 1 definition, tests, and Task 3 call site; `ShakeState` fields (`picks`, `categories`, `usedFallback`, `title`) used consistently in Task 3.
