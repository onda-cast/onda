# Per-Podcast Episode Search — Design

**Date:** 2026-07-17
**Status:** Approved, ready for implementation

## Goal

Let the user search for episodes *within a single podcast* by title, show-notes
metadata, and transcript text (when a transcript already exists). Example: inside a
news show's episode list, typing "Germany" returns every episode that mentions
Germany — in its title, its show notes, or its transcript.

## Scope

- **In:** A search bar on the per-podcast episode list (`EpisodeListView`) that
  filters that show's episodes in place. Episode-level results (one row per episode)
  with an optional transcript snippet showing why a transcript match hit. Simple
  keyword matching. Metadata-only episodes (no transcript yet) remain searchable by
  title/notes.
- **Out:** Global/cross-show search (already exists in `LibrarySearchView`). Natural-
  language speaker/show parsing (`SmartQueryParser`) — unnecessary here since the show
  is already fixed by context. Fuzzy matching, typo tolerance, ranking beyond date
  order.

## Architecture

### New: `PodcastEpisodeSearch` (`Onda/Search/PodcastEpisodeSearch.swift`)

A small `@MainActor` struct, sibling to `Onda/Transcription/TranscriptSearch.swift`,
returning episode-level results scoped to one podcast.

```swift
struct EpisodeSearchResult: Identifiable {
    var id: String { episode.guid }
    let episode: Episode
    let snippet: String?     // first matching transcript quote; nil if only title/notes matched
    let snippetStartTime: TimeInterval?  // cue start for seek-on-open; nil if metadata-only
}

@MainActor
struct PodcastEpisodeSearch {
    let index: SearchIndex?   // from SearchIndexBox; may be nil if not yet built
    func search(_ query: String, in podcast: Podcast) -> [EpisodeSearchResult]
}
```

**Matching logic:**

1. Trim/lowercase the query; split into whitespace-separated terms. Empty query →
   return `[]` (caller shows the normal browse list instead).
2. Consider only the podcast's non-archived episodes (`podcast.episodes` filtered on
   `!isArchived`), matching the exclusion `EpisodeFilter` already applies.
3. **Metadata match:** an episode matches if *every* term appears (case-insensitive
   substring) in `title` or `notes`.
4. **Transcript match:** query the FTS5 `SearchIndex` once with the raw query string
   (FTS5 applies implicit AND across terms), then keep only hits whose `episodeGuid`
   belongs to this podcast. For each such episode, record the first hit's snippet and
   `startTime`.
5. **Merge:** union of metadata matches and transcript matches, one result per episode.
   `snippet`/`snippetStartTime` populated from the transcript hit when present, else
   `nil`.
6. **Sort:** by `publishDate` descending — same order as the normal browse list, so
   searching doesn't reshuffle unexpectedly.

If `index` is `nil` or an episode has no transcript, it still participates via the
metadata path with `snippet: nil`.

### UI: `EpisodeListView.swift`

- Add `@State private var query = ""` and `@Environment(SearchIndexBox.self)`.
- Add a search bar above the filter chips, styled like `LibrarySearchView`'s bar
  (magnifying-glass `Image` + `TextField`, `.brutalBorder(width: 2.5)`,
  `.textInputAutocapitalization(.never)`).
- **Empty query:** unchanged behavior — existing `EpisodeFilter`-driven list.
- **Non-empty query:** hide the filter chips (a downloaded/all/newest10 filter doesn't
  compose with a text search) and render
  `PodcastEpisodeSearch(index:).search(query, in: podcast)` results instead.
- **Row:** extend `EpisodeRow` with an optional `snippet: String?` parameter. When
  present, render a short italic quoted line under the date/duration row (visual weight
  matching `LibrarySearchView`'s `cueText`). No new row type.
- **Empty results:** show `No episodes match "<query>"`.
- **Open:** tapping a result calls the existing `onPlay` (`playback.play(ep)`). When
  the match carried a transcript snippet, additionally seek to the cue —
  `playback.seek(toFraction: startTime / max(1, ep.duration))`, mirroring
  `LibrarySearchView.open`.

## Data flow

`TextField` → `query` state → `.onChange(of: query)` recomputes results via
`PodcastEpisodeSearch` (one show's episodes + one FTS lookup filtered by guid; cheap).
No new persistence, no schema change — reuses the existing `SearchIndex` FTS5 store
populated at transcript-ingest time (`TranscriptService`, `ClipService`).

## Edge cases

- **No transcript / index not built:** metadata-only match, handled inside
  `PodcastEpisodeSearch` — no special-casing in the view.
- **Archived episodes:** excluded, consistent with `EpisodeFilter`.
- **Multi-word queries** ("climate change"): AND semantics — all terms must match
  (title/notes substring, or FTS5 implicit AND for the transcript path).

## Testing

Unit tests for `PodcastEpisodeSearch.search` (mirroring `SmartQueryParserTests` style):

- Title match returns the episode, `snippet == nil`.
- Notes match returns the episode.
- Transcript-only match returns the episode with a non-nil `snippet` and start time.
- Multi-term query requires all terms (AND).
- Non-matching query returns `[]`.
- Archived episode excluded even when its text matches.
- `nil` index falls back to metadata-only without crashing.

This design deliberately avoids `SmartQueryParser`/`NLTagger`, so the NL-asset
flakiness that forced XCTSkip guards elsewhere (`docs/BUGS.md`) does not apply.
