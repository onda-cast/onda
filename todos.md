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

## Medium Priority

- [ ] **Transcript auto-scroll fights the user** — `Onda/Player/TranscriptView.swift:243-246` — the cue-count `onChange` auto-scrolls with none of the guards (`isFollowing`, cooldown) the position-based auto-scroll uses elsewhere.
- [ ] **Inconsistent tap-target sizing** — 44pt convention (`EpisodeListView`, `RecommendationRow`, player header icons) undershot by `EpisodeRow` (34×34, 30×30), `LibraryView`/`DiscoverView` icon buttons (36×36), transcript/clip-review controls (40×40).
- [ ] **Two incompatible swipe idioms coexist** — Discover's `SwipeToHide` (silent follow-the-finger, 90pt auto-commit) vs. Library's native `.swipeActions` (labeled, color-coded, reversible).
- [ ] **SwipeToHide's plain DragGesture can steal taps** — `Onda/Discover/RecommendationRow.swift:36` — layered over Follow/"×" buttons with no `.simultaneousGesture`/exclusion guard.
- [ ] **Feed refresh and recommendation candidate fetches are serial, not parallel** — `Onda/Services/FeedRefreshService.swift:38-49`, `Onda/Recommendations/CandidateRetriever.swift:30-31`, `Onda/Recommendations/CandidateReranker.swift:26-30`.
- [ ] **Feed refresh failures are silently swallowed** — `Onda/Services/FeedRefreshService.swift:47` — `catch { continue }`, no error state or retry surfaced.
- [ ] **Taste-profile scoring faults transcripts on the main actor** — `Onda/Recommendations/TasteProfile.swift:39-70`, called from `@MainActor` `RecommendationService.refresh`.
- [ ] **Retention eviction doesn't check what's currently playing** — `Onda/Services/EpisodeRetentionService.swift:76-105` — marking the live episode "played" can delete the file backing the active `AVPlayerItem` mid-playback.
- [ ] **QueueItem has no cascade rule** — `Onda/Models/QueueItem.swift:5-14` — deleting an episode leaves an orphaned queue row (`episode == nil`) that accumulates silently.
- [ ] **Transcript timestamps format inconsistently** — `Onda/Library/LibrarySearchView.swift:78-80` always shows `M:SS` even past an hour, while `TranscriptView` switches to `H:MM:SS`.
- [ ] **SRT/VTT end-timestamp parsing is fragile** — `Onda/Transcription/TranscriptParser.swift:39-44` — malformed cue lines can silently produce zero-length cues with no validation that end ≥ start.

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
