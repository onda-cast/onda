# Onda UX/Perf Review — 2026-07-20

Four-agent parallel review (Library/Discover, Player/Playback/Books/Clips, Profile/Settings/Downloads/Recommendations, Transcription/Search/Models/Theme). 37 findings: 9 High, 11 Medium, 9 Low.

## High Priority — ALL FIXED 2026-07-20

- [x] **Library grid faults SwiftData on every render** — fixed via new `Onda/Library/LatestEpisodeSubtitle.swift` (scoped limit-1 `@Query` sorted by `publishDate`, used by `ShowCard` and `LibraryView.rowCard`) instead of `podcast.episodes.first?.title`.
- [x] **BookMentionService mutates a SwiftData relationship while iterating it** — snapshot `episode.bookMentions` before the delete loop (`BookMentionService.swift`).
- [x] **"Find Books" verifies candidates one at a time, serially** — now uses `withTaskGroup` to verify concurrently (`BookMentionService.swift`).
- [x] **PlayerEngine leaks stale tap/observer state across episode switches** — `installTap` cancels the previous install task and checks `item === player.currentItem` before assigning; `addObservers` removes the prior end-of-item observer before adding a new one (`PlayerEngine.swift`).
- [x] **Retention "delete when finished" doesn't fire on natural playback completion** — `PlaybackManager` gained a `retention` property (wired in `OndaApp.swift`), called from both the 95%-tick mark-played and `handleEndOfItem`.
- [x] **Deleting a still-downloading episode can resurrect it** — `DownloadManager.delete()` now cancels the in-flight `URLSessionDownloadTask` and tombstones the guid so a race-landed `handleFinished` is a no-op.
- [x] **Hidden shows still consume Discover's recommendation budget** — `RecommendationService` takes a `HiddenShows` dependency (the app-wide shared instance) and filters in the `isDismissed` closure passed to `CandidateRetriever`, before the expensive rerank fetch.
- [x] **RSS feed parsing blocks the main thread** — `RSSFeedClient.fetchFeed` now runs `RSSFeedParser.parse` inside `Task.detached`; `ParsedFeed`/`ParsedEpisode`/`RSSFeedParser` marked `Sendable`.
- [x] **Library transcript search has no debounce** — `LibrarySearchView` now debounces 300ms (cancel-on-keystroke `Task`), matching Discover's search.

## Medium Priority — ALL FIXED 2026-07-20

- [x] **Transcript auto-scroll fights the user** — the `cueVMs.count` `onChange` now applies the same `isFollowing`/`!searching`/cooldown guards as the position-based auto-scroll (`TranscriptView.swift`).
- [x] **Inconsistent tap-target sizing** — bumped `EpisodeRow`'s play/download buttons, `LibraryView`/`DiscoverView`'s header icon buttons, and the transcript/clip-review 40pt controls to 44×44 (visible glyph kept smaller where space is tight, via an outer tap-frame + `.contentShape`).
- [x] **Two incompatible swipe idioms coexist** — `SwipeToHide` now reveals a labeled black "HIDE" background during the drag, closing the discoverability gap with Library's `.swipeActions` (the underlying full-swipe-to-commit mechanics are unchanged — a ScrollView row can't host the native control).
- [x] **SwipeToHide's plain DragGesture can steal taps** — `TrendingRow`'s Follow button and `RecommendationRow`'s dismiss "×" now carry a `.highPriorityGesture(TapGesture())` that always wins over the ancestor swipe gesture.
- [x] **Feed refresh and recommendation candidate fetches are serial, not parallel** — all three now fan out via unstructured `Task { @MainActor in ... }` arrays awaited together (`FeedRefreshService.refreshAll`, `CandidateRetriever.retrieve`, `CandidateReranker.rank`) — network fetches overlap while SwiftData writes stay serialized on the main actor.
- [x] **Feed refresh failures are silently swallowed** — `FeedRefreshService` now tracks `lastRefreshFailures: [String]` (show titles) per run and logs via `os.Logger`, instead of a bare `catch { continue }`.
- [x] **Taste-profile scoring faults transcripts on the main actor** — `RecommendationService.refresh` now rebuilds the profile inside `Task.detached` over a background `ModelContext`, same pattern as `StorageBreakdown`/`LibrarySortKeys`; `TasteProfileBuilder` is no longer `@MainActor`.
- [x] **Retention eviction doesn't check what's currently playing** — `EpisodeRetentionService` takes an `isCurrentlyPlaying: (Episode) -> Bool` closure (wired to `PlaybackManager.currentEpisode` in `OndaApp.swift`) and both eviction rules skip the live episode.
- [x] **QueueItem has no cascade rule** — `Episode` gained `@Relationship(deleteRule: .cascade, inverse: \QueueItem.episode) var queueItems` (additive, lightweight migration).
- [x] **Transcript timestamps format inconsistently** — new shared `Onda/Theme/TimeFormatting.swift`; both `TranscriptView` and `LibrarySearchView` now call it.
- [x] **SRT/VTT end-timestamp parsing is fragile** — `TranscriptParser` now skips a cue with a missing/empty end-timestamp token, and validates `end >= start` before accepting it.

## Fixed separately

- [x] **`TranscriptFollowProbeUITests` pre-existing failure** — root cause: cue text renders via `SelectableCueText` (a `UITextView`-backed `UIViewRepresentable`, added for native Look Up/Search Web selection), which surfaces to XCUITest through `.value`, not `.label` like a plain SwiftUI `Text`. The probe queried `app.staticTexts(label CONTAINS ...)`, which was never going to match a `UITextView`. Fixed by querying `app.textViews(value CONTAINS ...)` instead. Verified stable across 3 consecutive runs.

## Low Priority

- [ ] EpisodeListView's `episodes` computed property faulted twice per render — `Onda/Library/EpisodeListView.swift:36-38`.
- [ ] `NowPlayingCenter.update` rebuilds/reassigns the whole Now Playing Info dictionary every ~0.5s tick even when only position changed — `Onda/Playback/NowPlayingCenter.swift:56-67`.
- [ ] Hardcoded 400ms sleep to sequence transcript-sheet dismiss → player presentation — `Onda/Playback/PlaybackManager.swift:149-153`.
- [ ] No consistent sheet-dismiss convention (toolbar Done/Cancel vs. bare trailing icon vs. custom chevron) across BooksSheet/TranscriptView/NowPlayingView.
- [ ] DownloadsStorageView's empty state is a bare `Text`, not the shared `BrutalEmptyState` — `Onda/Profile/DownloadsStorageView.swift:38-40`.
- [ ] Global vs. per-show "limit downloads" uses a Toggle+stepper in one place and a SegmentedRow+stepper in the other — `Onda/Profile/RetentionSettingsSection.swift:33-42` vs. `Onda/Settings/ShowSettingsSheet.swift:77-89`.
- [ ] Show-name matching in natural-language search is substring-based, not word-boundary — `Onda/Search/SmartQuery.swift:40-46`.
- [ ] Search index's 2-character minimum silently returns empty for single-character/CJK queries — `Onda/Search/SearchIndex.swift:93-95`.
- [ ] ShowTranscriptsView recomputes a full cue scan on every render, not just query change — `Onda/Library/ShowTranscriptsView.swift:23-31`.
