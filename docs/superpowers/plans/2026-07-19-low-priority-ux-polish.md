# Low-Priority UX Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 10 remaining Low-priority findings from the 2026-07-19 four-surface UX review (items #24–34 of the consolidated list; #29 was already fixed in the Medium batch).

**Architecture:** Pure SwiftUI "MV" — `@Observable` services in the environment, SwiftData models, neo-brutalist theme system in `Onda/Theme/`. Every change here is view-layer polish plus two small service additions (recommendation undo, show preview); no schema additions (one dead schema field is *removed*).

**Tech Stack:** Swift 6 / SwiftUI, SwiftData, XcodeGen, SwiftLint, XCTest (unit + XCUITest probes).

## Global Constraints

- After adding/removing any file: run `xcodegen generate` (project.pbxproj is generated; never hand-edit).
- Build/test destination: `platform=iOS Simulator,name=iPhone 17`.
- Fonts: always `.scaledFont(size, weight:)` — never `.font(.system(size:))` (Dynamic Type).
- Small white text on an accent fill must use `theme.color(.accentStrong)`, never `.accent` (AA 4.5:1 in dark mode).
- Every interactive control: ≥44pt tap target, an `accessibilityLabel` when the glyph isn't self-describing, `.isSelected` trait for selected states, and a non-color shape cue (checkmark) for selection.
- SwiftLint must stay clean except these known pre-existing warnings: `ChapterGenerationServiceTests.swift` trailing comma; `PlaybackManager.swift` file/type length + large tuple; `OndaApp.swift` init length; `ArticleConversionService.swift` type length; `ClipService.swift` parameter count; blanket-disable warnings in two Article test files. Introducing any *other* warning is a task failure.
- Commit after every task. Do not push; the operator deploys.
- Verify command used throughout:
  `xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`

---

### Task 1: Theme the failed-download retry button (finding #28)

The failed-state download button in the episode row uses a hardcoded `.black` fill — nearly invisible against the `#111111` dark-mode background.

**Files:**
- Modify: `Onda/Library/EpisodeRow.swift` (the `downloadIcon` computed property, `case .failed` branch, ~line 103)

**Interfaces:**
- Consumes: `theme.color(_:)` from `AppTheme` (already in the view's environment).
- Produces: nothing new.

- [ ] **Step 1: Make the change**

In `Onda/Library/EpisodeRow.swift`, find:

```swift
        case .failed:
            Image(systemName: "arrow.clockwise")
                .scaledFont(13, weight: .black)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black)
                .brutalBorder(width: 2)
```

Replace the `.background(.black)` line so the failed state reads in both schemes (red = needs attention, and `.red` on white glyph passes contrast at this weight/size for a status icon; the brutal border provides the edge):

```swift
        case .failed:
            Image(systemName: "arrow.clockwise")
                .scaledFont(13, weight: .black)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.red)   // themed attention color — hardcoded .black vanished in dark mode
                .brutalBorder(width: 2)
```

Note: `.red` is deliberate — the swipe-delete tint in `EpisodeListView` uses `.black` *as a styled choice on a system-red control*, but a failed download is an error state; red matches the failure text color used in `TranscriptView` (`.foregroundStyle(.red)`).

- [ ] **Step 2: Build**

Run the verify command from Global Constraints. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Lint**

Run: `swiftlint lint --quiet Onda/Library/EpisodeRow.swift`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Onda/Library/EpisodeRow.swift
git commit -m "Theme the failed-download button: red error fill instead of hardcoded black"
```

---

### Task 2: Mark the storage total as an estimate (finding #33)

The Downloads & Storage headline total mixes exact audio bytes with *estimated* transcript bytes but displays with no `~`; the per-row legends already use `~` for transcripts.

**Files:**
- Modify: `Onda/Profile/DownloadsStorageView.swift` (the type-bar card header, ~line 94)

**Interfaces:** none.

- [ ] **Step 1: Make the change**

In `Onda/Profile/DownloadsStorageView.swift`, find:

```swift
                    Text(sizeStr(bd.totalBytes)).scaledFont(15, weight: .bold).monospacedDigit()
                        .foregroundStyle(theme.color(.text))
```

Replace with:

```swift
                    // "~" because transcript bytes are estimated from cue text length
                    // (StorageBreakdown) — the legends below already mark them "~".
                    Text("~" + sizeStr(bd.totalBytes)).scaledFont(15, weight: .bold).monospacedDigit()
                        .foregroundStyle(theme.color(.text))
```

- [ ] **Step 2: Build + lint**

Run the verify command; expected `** BUILD SUCCEEDED **`.
Run: `swiftlint lint --quiet Onda/Profile/DownloadsStorageView.swift` — expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Onda/Profile/DownloadsStorageView.swift
git commit -m "Storage total shows ~ prefix: transcript bytes are estimated"
```

---

### Task 3: Custom speed seeds one step off the global (finding #34)

Per-show "Custom" speed seeds from the global default, so a freshly-selected Custom is indistinguishable from Default until cycled.

**Files:**
- Modify: `Onda/Settings/ShowSettingsSheet.swift` (`speedSteps` property, `speedOverrideRow`, `cycleSpeed`)
- Create: `OndaTests/ShowSettingsSpeedSeedTests.swift`

**Interfaces:**
- Produces: `static func customSpeedSeed(from global: Double) -> Double` and `static let speedSteps: [Double]` on `ShowSettingsSheet` (internal, for the test).

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ShowSettingsSpeedSeedTests.swift`:

```swift
//  ShowSettingsSpeedSeedTests.swift
import XCTest
@testable import Onda

@MainActor
final class ShowSettingsSpeedSeedTests: XCTestCase {
    func test_seed_isNextStepAboveGlobal() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.0), 1.25,
                       "a fresh Custom must be visibly different from Default")
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.5), 1.75)
    }

    func test_seed_wrapsAtTopOfRange() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 2.0), 0.75)
    }

    func test_seed_offGridGlobal_snapsToNextHigherStep() {
        XCTAssertEqual(ShowSettingsSheet.customSpeedSeed(from: 1.1), 1.25)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ShowSettingsSpeedSeedTests 2>&1 | grep -E "error:|passed|failed|\*\* TEST"`
Expected: build error `type 'ShowSettingsSheet' has no member 'customSpeedSeed'`.

- [ ] **Step 3: Implement**

In `Onda/Settings/ShowSettingsSheet.swift`, find:

```swift
    private let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
```

Replace with:

```swift
    static let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    private var speedSteps: [Double] { Self.speedSteps }

    /// Where a fresh "Custom" speed starts: the next step ABOVE the global default (wrapping),
    /// so choosing Custom is immediately visible instead of silently mirroring Default.
    static func customSpeedSeed(from global: Double) -> Double {
        speedSteps.first { $0 > global } ?? speedSteps[0]
    }
```

Then in `speedOverrideRow`, find:

```swift
            SegmentedRow(options: [("Default", 0), ("Custom", 1)],
                         selection: s.speed == nil ? 0 : 1) {
                s.speed = $0 == 0 ? nil : appSettings.defaultSpeed
                playback.applyAudioSettings()
            }
```

Replace with:

```swift
            SegmentedRow(options: [("Default", 0), ("Custom", 1)],
                         selection: s.speed == nil ? 0 : 1) {
                s.speed = $0 == 0 ? nil : Self.customSpeedSeed(from: appSettings.defaultSpeed)
                playback.applyAudioSettings()
            }
```

Also update the comment above `speedOverrideRow` from "seeded from the current global so tapping it starts from a familiar value" to "seeded one step above the global so the override is immediately visible".

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: 3 tests passed, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Lint + commit**

Run: `swiftlint lint --quiet Onda/Settings/ShowSettingsSheet.swift OndaTests/ShowSettingsSpeedSeedTests.swift` — expected no output.

```bash
git add Onda/Settings/ShowSettingsSheet.swift OndaTests/ShowSettingsSpeedSeedTests.swift Onda.xcodeproj/project.pbxproj
git commit -m "Per-show Custom speed seeds one step above the global default"
```

---

### Task 4: Remove the dead `notifMode` setting (finding #32)

`ShowSettings.notifMode` exists in the model but no UI renders it and no notification system exists in the app. Dead weight that reads as a broken promise — remove it. (SwiftData lightweight migration silently drops removed attributes.)

**Files:**
- Modify: `Onda/Models/ShowSettings.swift` (property ~line 15, init param ~line 26, assignment ~line 34)
- Modify: `OndaTests/ModelTests.swift:73` (assertion on the removed field)

**Interfaces:**
- Removes: `ShowSettings.notifMode`. Verified unused elsewhere: `grep -rn notifMode Onda OndaTests` currently returns only the four lines listed above.

- [ ] **Step 1: Re-verify the field is unreferenced**

Run: `grep -rn "notifMode" Onda OndaTests OndaUITests`
Expected: hits ONLY in `Onda/Models/ShowSettings.swift` (3 lines) and `OndaTests/ModelTests.swift` (1 line). If anything else appears, STOP and report instead of deleting.

- [ ] **Step 2: Remove from the model**

In `Onda/Models/ShowSettings.swift`:
- Delete the line: `var notifMode: String       // "all" | "important" | "none"`
- In the init signature, change `introTrimSec: Int = 0, outroTrimSec: Int = 0, notifMode: String = "all") {` to `introTrimSec: Int = 0, outroTrimSec: Int = 0) {`
- Delete the line: `self.notifMode = notifMode`

- [ ] **Step 3: Remove the test assertion**

In `OndaTests/ModelTests.swift`, delete the line:

```swift
        XCTAssertEqual(s.notifMode, "all")
```

- [ ] **Step 4: Run the full unit suite (migration + regressions)**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests 2>&1 | grep -E "error:|failed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Onda/Models/ShowSettings.swift OndaTests/ModelTests.swift
git commit -m "Remove dead ShowSettings.notifMode - no notification system exists to honor it"
```

---

### Task 5: Shared `BrutalEmptyState` component (finding #31)

Empty states are all text-only `textTertiary` labels but with drifting top offsets (80 / 60 / 48 / 24) and no shared component.

**Files:**
- Create: `Onda/Theme/BrutalEmptyState.swift`
- Modify: `Onda/Shell/LibraryView.swift` ("No shows yet" ~line 152, and the "No \(filter) episodes" branch inside `filteredEpisodeList`)
- Modify: `Onda/Clips/ClipsView.swift` (empty-results branch ~line 39)
- Modify: `Onda/Library/EpisodeListView.swift` ("No episodes match" branch ~line 66)
- Modify: `Onda/Library/LibrarySearchView.swift` (replace its private `emptyState(_:detail:)` helper)

**Interfaces:**
- Produces: `struct BrutalEmptyState: View` with `init(_ title: String, detail: String? = nil)`.

- [ ] **Step 1: Create the component**

Create `Onda/Theme/BrutalEmptyState.swift`:

```swift
//  BrutalEmptyState.swift
import SwiftUI

/// The single empty-state look for every surface — title + optional detail, one offset —
/// extracted because four hand-rolled versions had drifted in placement and styling.
struct BrutalEmptyState: View {
    @Environment(AppTheme.self) private var theme
    private let title: String
    private let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).scaledFont(14, weight: .semibold)
                .foregroundStyle(theme.color(.textSecondary))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).scaledFont(12)
                    .foregroundStyle(theme.color(.textTertiary))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 48)
    }
}
```

- [ ] **Step 2: Adopt in LibraryView**

In `Onda/Shell/LibraryView.swift`, find:

```swift
                        Text("No shows yet — find some in Discover")
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 80)
```

Replace with:

```swift
                        BrutalEmptyState("No shows yet", detail: "Find some in Discover.")
```

Then in the `filteredEpisodeList(_:)` extension, find:

```swift
            Text("No \(filter.label.lowercased()) episodes")
                .foregroundStyle(theme.color(.textTertiary))
                .frame(maxWidth: .infinity).padding(.top, 60)
```

Replace with:

```swift
            BrutalEmptyState("No \(filter.label.lowercased()) episodes")
```

- [ ] **Step 3: Adopt in ClipsView**

In `Onda/Clips/ClipsView.swift`, find:

```swift
                    if results.isEmpty {
                        Text(emptyStateText)
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 60)
```

Replace with:

```swift
                    if results.isEmpty {
                        BrutalEmptyState(query.isEmpty ? "No clips yet" : "No clips match",
                                         detail: query.isEmpty ? emptyStateDetail : nil)
```

Then replace the `emptyStateText` computed property:

```swift
    private var emptyStateText: String {
        guard query.isEmpty else { return "No clips match" }
        let secs = Int(ClipService.quickClipWindow)
        return "No clips yet — tap the scissors in the player, select transcript lines, or tap "
            + "the bookmark on your lock screen to save the last \(secs)s."
    }
```

with:

```swift
    private var emptyStateDetail: String {
        let secs = Int(ClipService.quickClipWindow)
        return "Tap the scissors in the player, select transcript lines, or tap the bookmark "
            + "on your lock screen to save the last \(secs)s."
    }
```

- [ ] **Step 4: Adopt in EpisodeListView**

In `Onda/Library/EpisodeListView.swift`, find:

```swift
                if isSearching && results.isEmpty {
                    Text("No episodes match “\(query)”")
                        .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
```

Replace with:

```swift
                if isSearching && results.isEmpty {
                    BrutalEmptyState("No episodes match “\(query)”")
                }
```

- [ ] **Step 5: Adopt in LibrarySearchView**

In `Onda/Library/LibrarySearchView.swift`, delete the private helper:

```swift
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).scaledFont(14, weight: .semibold).foregroundStyle(theme.color(.textSecondary))
            Text(detail).scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.top, 48)
    }
```

and change its two call sites from `emptyState(` / `emptyState("No matches for...` to the component (note the argument label difference — the component takes the title unlabeled and `detail:` stays):

```swift
                if !isSearching {
                    BrutalEmptyState(
                        "Search across every transcript",
                        detail: "Find a phrase, topic, or speaker from any episode you\u{2019}ve transcribed.")
                } else if hits.isEmpty {
                    BrutalEmptyState("No matches for \u{201C}\(query)\u{201D}",
                        detail: "Try a shorter phrase, or a different show/speaker name.")
                } else {
```

- [ ] **Step 6: Regenerate, build, run probes**

Run: `xcodegen generate`, then the verify build command — expected `** BUILD SUCCEEDED **`.
Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaUITests/LibraryFreezeProbeUITests -only-testing:OndaUITests/EpisodeSearchUITests 2>&1 | grep -E "passed|failed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` (these probes traverse the Library and episode-search surfaces the edits touch).

- [ ] **Step 7: Commit**

```bash
git add Onda/Theme/BrutalEmptyState.swift Onda/Shell/LibraryView.swift Onda/Clips/ClipsView.swift Onda/Library/EpisodeListView.swift Onda/Library/LibrarySearchView.swift Onda.xcodeproj/project.pbxproj
git commit -m "Shared BrutalEmptyState replaces four drifted empty-state implementations"
```

---

### Task 6: Chrome on the destructive Unsubscribe button (finding #26)

The unsubscribe/delete action under the show title is bare 13pt red text with a small hit area, easy to mis-tap.

**Files:**
- Modify: `Onda/Library/EpisodeListView.swift` (header, ~line 219)

**Interfaces:** none (the existing confirmation dialog stays).

- [ ] **Step 1: Make the change**

Find:

```swift
                Button(podcast.isLocal ? "Delete Show" : "Unsubscribe") { pendingUnsubscribe = true }
                    .scaledFont(13, weight: .bold).foregroundStyle(.red)
```

Replace with (real button chrome, ≥44pt hit height via frame, separated from the title):

```swift
                Button { pendingUnsubscribe = true } label: {
                    Text(podcast.isLocal ? "Delete Show" : "Unsubscribe")
                        .scaledFont(13, weight: .bold).foregroundStyle(.red)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        .frame(minHeight: 44).contentShape(Rectangle())   // HIG tap target
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
```

Keep any modifiers that followed the original button (e.g. `.buttonStyle(.plain)` if present — do not double-apply; check the surrounding lines after replacing).

- [ ] **Step 2: Build + lint + commit**

Run the verify build command — expected `** BUILD SUCCEEDED **`.
Run: `swiftlint lint --quiet Onda/Library/EpisodeListView.swift` — expected no output.

```bash
git add Onda/Library/EpisodeListView.swift
git commit -m "Unsubscribe gets real button chrome and a 44pt target"
```

---

### Task 7: Category chips become real filters (findings #24 + #30)

Tapping a category chip currently writes the category into the search box (`query = cat`), so chips *look* like Library's filter chips but behave like a search shortcut. Make them true toggle filters: selection never touches the visible search text, selected chips get the standard checkmark + `accentStrong` treatment, and the list header names the category.

**Files:**
- Modify: `Onda/Shell/DiscoverView.swift` (`categoryChips`, `listItems`, `listHeader`, new state + fetch function, `onChange(of: query)`)

**Interfaces:**
- Consumes: `clientBox.client.search(term:)` (`Searching` protocol, already used by `runSearch`).
- Produces (view-internal): `@State selectedCategory: String?`, `@State categoryResults: [PodcastDTO]`, `func selectCategory(_ cat: String?)`.

- [ ] **Step 1: Add state**

In `DiscoverView`'s state block (below `@State private var showAddByURL = false`), add:

```swift
    // Category chips are real filters: selection drives its own result set and NEVER writes
    // into the visible search text (that made them read as a search shortcut, unlike every
    // other chip in the app).
    @State private var selectedCategory: String?
    @State private var categoryResults: [PodcastDTO] = []
```

- [ ] **Step 2: Rewrite `categoryChips`**

Replace the whole `categoryChips` computed property:

```swift
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    let selected = selectedCategory == cat
                    Button { selectCategory(selected ? nil : cat) } label: {
                        HStack(spacing: 4) {
                            if selected {
                                Image(systemName: "checkmark").scaledFont(10, weight: .black)
                            }
                            Text(cat).brutalHeader(size: 11.5)
                        }
                        .foregroundStyle(selected ? .white : theme.color(.text))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(selected ? theme.color(.accentStrong) : theme.color(.bgElevated))
                        .brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }
```

- [ ] **Step 3: Add the fetch function**

In the `// MARK: - Data loading & shake` extension (next to `runSearch`), add:

```swift
    /// Category chip tap: toggles a category browse with its own result set. Typing a search
    /// clears it (see onChange(of: query)); the visible query text is never modified.
    func selectCategory(_ cat: String?) {
        selectedCategory = cat
        categoryResults = []
        shake = nil
        guard let cat else { return }
        Task { [clientBox] in
            let found = (try? await clientBox.client.search(term: cat)) ?? []
            // Only publish if this category is still the selected one (user may have moved on).
            if selectedCategory == cat { categoryResults = found }
        }
    }
```

- [ ] **Step 4: Wire precedence + header + query interaction**

Replace `listItems`:

```swift
    private var listItems: [PodcastDTO] {
        if let picks = shake?.picks { return picks }
        if !results.isEmpty { return results }
        if selectedCategory != nil { return categoryResults }
        return trending
    }
```

Replace the non-shake branch of `listHeader`:

```swift
        } else {
            Text(!results.isEmpty ? "Results"
                 : selectedCategory.map { $0.uppercased() } ?? "Trending Today")
                .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
        }
```

In the existing `.onChange(of: query)` in `body`, add category clearing — find:

```swift
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { shake = nil }
            Task { await runSearch(new) }
        }
```

Replace with:

```swift
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty {
                shake = nil
                selectedCategory = nil; categoryResults = []   // typed search supersedes a category
            }
            Task { await runSearch(new) }
        }
```

- [ ] **Step 5: Loading state while a category fetches**

In `browseStatus`, the `else if shake == nil && trending.isEmpty` branch only covers trending. Add a category branch — replace the whole `browseStatus` property:

```swift
    // Distinguish loading / error / genuinely-empty so a network failure never looks like "no results".
    @ViewBuilder private var browseStatus: some View {
        if isSearching {
            if searchFailed {
                errorRetry("Search failed — check your connection") { Task { await runSearch(query) } }
            } else if !searching && results.isEmpty {
                statusNote("No results for “\(query)”")
            }
        } else if let cat = selectedCategory, categoryResults.isEmpty {
            loadingRow("Loading \(cat)…")
        } else if shake == nil && trending.isEmpty {
            if loading {
                loadingRow("Loading trending…")
            } else if trendingFailed {
                errorRetry("Couldn't load trending") { Task { await clientBox.loadTrendingIfNeeded(force: true) } }
            }
        }
    }
```

- [ ] **Step 6: Build + probe**

Run the verify build command — expected `** BUILD SUCCEEDED **`.
Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaUITests/MiniPlayerProbeUITests 2>&1 | grep -E "passed|failed|\*\* TEST"` (this probe drives Discover including its search field). Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Onda/Shell/DiscoverView.swift
git commit -m "Discover category chips are real filters: own result set, checkmark cue, no query pollution"
```

---

### Task 8: Visible "Not interested" with undo (finding #25)

Dismissing a recommendation is long-press-only and permanent. Add a visible ✕ on each For You row and an undo toast; the persisted dismissal becomes reversible.

**Files:**
- Modify: `Onda/Recommendations/Recommendation.swift` (`DismissedShows` — add `undismiss`)
- Modify: `Onda/Recommendations/RecommendationService.swift` (track last dismissal; add `undoDismiss()`)
- Modify: `Onda/Shell/DiscoverView.swift` (`forYouTab` row + undo toast state)
- Modify: `OndaTests/RecommendationPipelineTests.swift` (new test)

**Interfaces:**
- Produces: `DismissedShows.undismiss(_ dto: PodcastDTO)`; `RecommendationService.dismiss(_ rec:)` (unchanged signature), `RecommendationService.undoDismiss()`, `RecommendationService.lastDismissed: Recommendation?` (read-only for the UI).

- [ ] **Step 1: Write the failing test**

Append to `OndaTests/RecommendationPipelineTests.swift`, just above the final `private func freshDefaults()` line:

```swift
    func test_dismiss_thenUndo_restoresRecAndUnpersists() async throws {
        let ctx = try ctx()
        let defaults = freshDefaults()
        let chart = dto("Top Show", feed: "https://top.com/f.xml")
        let client = StubSearch(chartIds: [1], chartLookup: [chart])
        let feeds = StubFeeds(byURL: [URL(string: "https://top.com/f.xml")!:
                                        feed("Top Show", episodes: [("Ep", "hi")])])
        let svc = RecommendationService(modelContext: ctx, client: client, feeds: feeds, embedding: nil,
                                        searchLog: SearchTermLog(defaults: defaults),
                                        dismissed: DismissedShows(defaults: defaults))
        await svc.refresh(followedCategories: [])
        XCTAssertEqual(svc.recommendations.count, 1)

        svc.dismiss(svc.recommendations[0])
        XCTAssertTrue(svc.recommendations.isEmpty)
        XCTAssertNotNil(svc.lastDismissed)

        svc.undoDismiss()
        XCTAssertEqual(svc.recommendations.map(\.dto.collectionName), ["Top Show"],
                       "undo restores the recommendation in place")
        XCTAssertFalse(DismissedShows(defaults: defaults).contains(chart),
                       "undo also removes the persisted dismissal")
        XCTAssertNil(svc.lastDismissed)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/RecommendationPipelineTests 2>&1 | grep -E "error:|failed|\*\* TEST"`
Expected: build error `value of type 'RecommendationService' has no member 'lastDismissed'`.

- [ ] **Step 3: Implement `undismiss` on DismissedShows**

In `Onda/Recommendations/Recommendation.swift`, inside `final class DismissedShows`, after `dismiss(_:)`, add:

```swift
    func undismiss(_ dto: PodcastDTO) {
        guard let feed = dto.feedUrl?.absoluteString else { return }
        feeds.remove(feed)
    }
```

- [ ] **Step 4: Implement dismissal tracking + undo on RecommendationService**

In `Onda/Recommendations/RecommendationService.swift`, find:

```swift
    /// Marks a recommendation "not interested": adds it to the persistent dismissed set (so it
    /// won't return) and removes it from the current list.
    func dismiss(_ rec: Recommendation) {
        dismissedStore.dismiss(rec.dto)
        recommendations.removeAll { $0.id == rec.id }
    }
```

Replace with:

```swift
    /// The most recent dismissal, kept so the UI can offer Undo. Cleared by the next refresh,
    /// the next dismissal (replaced), or a successful undo.
    private(set) var lastDismissed: Recommendation?
    private var lastDismissedIndex: Int = 0

    /// Marks a recommendation "not interested": adds it to the persistent dismissed set (so it
    /// won't return) and removes it from the current list. Reversible via ``undoDismiss()``.
    func dismiss(_ rec: Recommendation) {
        lastDismissedIndex = recommendations.firstIndex { $0.id == rec.id } ?? 0
        lastDismissed = rec
        dismissedStore.dismiss(rec.dto)
        recommendations.removeAll { $0.id == rec.id }
    }

    /// Reverses the most recent ``dismiss(_:)``: un-persists it and restores the row in place.
    func undoDismiss() {
        guard let rec = lastDismissed else { return }
        dismissedStore.undismiss(rec.dto)
        recommendations.insert(rec, at: min(lastDismissedIndex, recommendations.count))
        lastDismissed = nil
    }
```

Also clear the pending undo on refresh — in `refresh(followedCategories:excluding:)`, immediately after `isLoading = true`, add:

```swift
        lastDismissed = nil
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 2. Expected: `** TEST SUCCEEDED **` (all RecommendationPipelineTests, including the new one).

- [ ] **Step 6: UI — visible ✕ + undo toast**

In `Onda/Shell/DiscoverView.swift`, in `forYouTab` (in the `// MARK: - For You sub-tab` extension), find:

```swift
            ForEach(recs.recommendations) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    TrendingRow(dto: rec.dto, isSubscribed: isSubscribed(rec.dto)) { toggleFollow(rec.dto) }
                    if let reason = rec.reasonLine {
                        Text(reason).scaledFont(11.5).foregroundStyle(theme.color(.textTertiary))
                            .padding(.leading, 2)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { recs.dismiss(rec) } label: {
                        Label("Not interested", systemImage: "hand.thumbsdown")
                    }
                }
            }
```

Replace with:

```swift
            ForEach(recs.recommendations) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TrendingRow(dto: rec.dto, isSubscribed: isSubscribed(rec.dto)) { toggleFollow(rec.dto) }
                        // Visible "not interested" — the context menu below stays as the
                        // secondary path, but discoverability needs an on-screen control.
                        Button { dismissRecommendation(rec) } label: {
                            Image(systemName: "xmark").scaledFont(12, weight: .bold)
                                .foregroundStyle(theme.color(.textTertiary))
                                .frame(width: 32, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Not interested in \(rec.dto.collectionName)")
                    }
                    if let reason = rec.reasonLine {
                        Text(reason).scaledFont(11.5).foregroundStyle(theme.color(.textTertiary))
                            .padding(.leading, 2)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { dismissRecommendation(rec) } label: {
                        Label("Not interested", systemImage: "hand.thumbsdown")
                    }
                }
            }
```

Add to `DiscoverView`'s state block:

```swift
    @State private var undoToastTask: Task<Void, Never>?
    @State private var showUndoToast = false
```

Add these two pieces to the `// MARK: - For You sub-tab` extension:

```swift
    func dismissRecommendation(_ rec: Recommendation) {
        recs.dismiss(rec)
        withAnimation { showUndoToast = true }
        undoToastTask?.cancel()
        undoToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation { showUndoToast = false } }
        }
    }
```

In `body`, directly after the existing plain-toast `.overlay(alignment: .bottom) { ... }` block, add a second overlay:

```swift
        .overlay(alignment: .bottom) {
            if showUndoToast, let rec = recs.lastDismissed {
                Button {
                    undoToastTask?.cancel()
                    withAnimation { showUndoToast = false }
                    recs.undoDismiss()
                } label: {
                    Text("Not interested: \(rec.dto.collectionName) \u{2014} UNDO")
                        .scaledFont(13.5, weight: .semibold).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(theme.color(.accentStrong)).brutalBorder(width: 2).hardShadow(offset: 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel("Dismissed \(rec.dto.collectionName). Double-tap to undo.")
            }
        }
```

(Deliberately not `BrutalToast`: this one is a Button with an action, and `BrutalToast` posts its own VoiceOver announcement + has no tap affordance. The visual recipe matches.)

- [ ] **Step 7: Build + lint + commit**

Run the verify build command — expected `** BUILD SUCCEEDED **`.
Run: `swiftlint lint --quiet Onda/Shell/DiscoverView.swift Onda/Recommendations/RecommendationService.swift Onda/Recommendations/Recommendation.swift` — expected no output.

```bash
git add Onda/Recommendations/Recommendation.swift Onda/Recommendations/RecommendationService.swift Onda/Shell/DiscoverView.swift OndaTests/RecommendationPipelineTests.swift
git commit -m "For You: visible not-interested control with undo toast; dismissals reversible"
```

---

### Task 9: Tap a trending/recommendation row to preview the show (finding #27)

Rows are only interactive via their Follow button; there's no way to see a show's episodes before committing.

**Files:**
- Create: `Onda/Discover/ShowPreviewSheet.swift`
- Modify: `Onda/Shell/DiscoverView.swift` (row wiring in `browseTab` + `forYouTab`, preview state + sheet)

**Interfaces:**
- Consumes: `SubscriptionService.previewFeed(_ url: URL) async throws -> ParsedFeed` (exists — the AddByURLSheet preview path), `ParsedFeed` fields: `title`, `author`, `artworkURL`, `category`, `episodes: [ParsedEpisode]` with `title`, `publishDate`.
- Produces: `struct ShowPreviewSheet: View` with `init(dto: PodcastDTO, isSubscribed: Bool, onToggle: @escaping () -> Void)`; `struct PreviewTarget: Identifiable` (view-file-private wrapper in DiscoverView).

- [ ] **Step 1: Create the sheet**

Create `Onda/Discover/ShowPreviewSheet.swift`:

```swift
//  ShowPreviewSheet.swift
//  Lightweight look-before-you-follow: artwork, metadata, and the latest episodes of a
//  Discover result, fetched from its public feed. Follow works from here too.
import SwiftUI

struct ShowPreviewSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    let dto: PodcastDTO
    let isSubscribed: Bool
    var onToggle: () -> Void

    @State private var feed: ParsedFeed?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ArtworkView(url: dto.artworkUrl600, seed: dto.collectionName)
                        .frame(width: 88, height: 88).hardShadow(offset: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dto.collectionName).brutalHeader(size: 16)
                            .foregroundStyle(theme.color(.text)).lineLimit(2)
                        Text(dto.artistName).scaledFont(13)
                            .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                        Text(dto.primaryGenreName ?? "Podcast").scaledFont(12)
                            .foregroundStyle(theme.color(.textTertiary))
                    }
                    Spacer(minLength: 0)
                }

                Button(action: onToggle) {
                    Text(isSubscribed ? "Following" : "Follow")
                        .scaledFont(14, weight: .bold).textCase(.uppercase)
                        .foregroundStyle(isSubscribed ? theme.color(.textSecondary) : .white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(isSubscribed ? theme.color(.bgElevated) : theme.color(.accentStrong))
                        .brutalBorder(width: 2.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSubscribed ? "Following \(dto.collectionName), tap to unfollow"
                                                 : "Follow \(dto.collectionName)")

                Text("Latest Episodes").brutalHeader(size: 13)
                    .foregroundStyle(theme.color(.textTertiary))

                if let feed {
                    ForEach(Array(feed.episodes.prefix(8).enumerated()), id: \.offset) { _, ep in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).scaledFont(14, weight: .semibold)
                                .foregroundStyle(theme.color(.text)).lineLimit(2)
                            Text(ep.publishDate.formatted(.relative(presentation: .named)))
                                .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }
                } else if failed {
                    BrutalEmptyState("Couldn\u{2019}t load this show\u{2019}s feed",
                                     detail: "You can still follow it \u{2014} episodes load after subscribing.")
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.color(.accent))
                        Text("Loading episodes\u{2026}").scaledFont(13)
                            .foregroundStyle(theme.color(.textTertiary))
                    }.frame(maxWidth: .infinity).padding(.top, 12)
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .task {
            guard let url = dto.feedUrl else { failed = true; return }
            do { feed = try await subscriptions.previewFeed(url) } catch { failed = true }
        }
    }
}
```

(Requires Task 5's `BrutalEmptyState`. If executing this task before Task 5, replace that one usage with a plain `Text(...)` and revisit.)

- [ ] **Step 2: Wire row taps in DiscoverView**

In `Onda/Shell/DiscoverView.swift`, add to the state block:

```swift
    // Row tap → show preview. Identifiable wrapper because PodcastDTO itself isn't Identifiable.
    struct PreviewTarget: Identifiable {
        let id = UUID()
        let dto: PodcastDTO
    }
    @State private var previewTarget: PreviewTarget?
```

In `browseTab`, find:

```swift
            ForEach(Array(listItems.enumerated()), id: \.element.collectionId) { i, dto in
                let row = TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) { toggleFollow(dto) }
                if shake != nil {
                    DealtCard(index: i) { row }
                } else {
                    row
                }
            }
```

Replace with:

```swift
            ForEach(Array(listItems.enumerated()), id: \.element.collectionId) { i, dto in
                // Row tap opens a preview; the inner Follow Button still wins its own taps.
                let row = TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) { toggleFollow(dto) }
                    .contentShape(Rectangle())
                    .onTapGesture { previewTarget = PreviewTarget(dto: dto) }
                    .accessibilityHint("Opens a preview of this show")
                if shake != nil {
                    DealtCard(index: i) { row }
                } else {
                    row
                }
            }
```

In `forYouTab` (after Task 8's edit), apply the same two modifiers to its `TrendingRow` — find the `TrendingRow(dto: rec.dto, ...)` line inside the `HStack(spacing: 8)` and change it to:

```swift
                        TrendingRow(dto: rec.dto, isSubscribed: isSubscribed(rec.dto)) { toggleFollow(rec.dto) }
                            .contentShape(Rectangle())
                            .onTapGesture { previewTarget = PreviewTarget(dto: rec.dto) }
                            .accessibilityHint("Opens a preview of this show")
```

In `body`, next to the other `.sheet` modifiers, add:

```swift
        .sheet(item: $previewTarget) { target in
            ShowPreviewSheet(dto: target.dto,
                             isSubscribed: isSubscribed(target.dto),
                             onToggle: { toggleFollow(target.dto) })
                .presentationDetents([.medium, .large])
        }
```

- [ ] **Step 3: Regenerate, build, probe**

Run: `xcodegen generate`, then the verify build command — expected `** BUILD SUCCEEDED **`.
Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaUITests/MiniPlayerProbeUITests 2>&1 | grep -E "passed|failed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`. (The probe scrolls/drags over Discover rows; drags must NOT trigger the new tap gesture — `onTapGesture` only fires on discrete taps, so this doubles as a regression check.)

- [ ] **Step 4: Commit**

```bash
git add Onda/Discover/ShowPreviewSheet.swift Onda/Shell/DiscoverView.swift Onda.xcodeproj/project.pbxproj
git commit -m "Tap a Discover row to preview the show before following"
```

---

### Task 10: Final verification sweep

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests 2>&1 | grep -E "failed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: UI probes on a fresh dedicated simulator** (per `onda:verify` skill — don't fight sibling agents for the shared sim)

```bash
RUNTIME=$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS[^ )]*' | tail -1)
UDID=$(xcrun simctl create onda-lowpolish-verify com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RUNTIME")
xcrun simctl boot "$UDID"
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" -derivedDataPath /tmp/onda-verify-dd \
  -only-testing:OndaUITests/MiniPlayerProbeUITests \
  -only-testing:OndaUITests/LibraryFreezeProbeUITests \
  -only-testing:OndaUITests/EpisodeSearchUITests 2>&1 | grep -E "passed|failed|\*\* TEST"
xcrun simctl shutdown "$UDID"; xcrun simctl delete "$UDID"
```

Expected: all pass.

- [ ] **Step 3: Full lint**

Run: `swiftlint lint --quiet | grep -vE "ChapterGenerationServiceTests|PlaybackManager.swift|OndaApp.swift|ArticleConversionService.swift|ClipService.swift|ArticleConversionServiceTests|PendingArticlesQueueTests"`
Expected: no output (only the grandfathered warnings filtered above may exist).

- [ ] **Step 4: Report**

Do NOT push or deploy — summarize per-task status to the operator, who pushes to origin and installs the Release build on the device.

---

## Self-Review Notes

- **Coverage:** #24+#30 → Task 7; #25 → Task 8; #26 → Task 6; #27 → Task 9; #28 → Task 1; #31 → Task 5; #32 → Task 4; #33 → Task 2; #34 → Task 3. #29 (clip-row play a11y label) was already fixed in commit `2fe6d6e` — intentionally absent.
- **Ordering dependency:** Task 9 uses `BrutalEmptyState` from Task 5 (fallback documented inline). Task 9's `forYouTab` edit assumes Task 8's `HStack` restructure (exact code shown for the post-Task-8 shape).
- **Types cross-check:** `customSpeedSeed(from:)` static on `ShowSettingsSheet` (Tasks 3); `DismissedShows.undismiss(_:)` / `RecommendationService.lastDismissed` / `undoDismiss()` consistent across Task 8's test and implementation; `PreviewTarget` defined and consumed only in Task 9.
