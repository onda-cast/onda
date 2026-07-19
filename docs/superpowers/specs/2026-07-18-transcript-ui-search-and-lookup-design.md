# Transcript UI: in-panel search & word lookup

**Date:** 2026-07-18 (revised same day after selection spike — see Feature 2)
**Status:** Approved design, ready for implementation plan
**Scope:** `Onda/Player/TranscriptView.swift`, plus two small new components (`SelectableCueText`
UIKit wrapper, `TranscriptFind` match logic). No model/schema changes, no networking.

## Goal

Make the transcript panel nicer to read and work in by adding two capabilities:

1. **In-panel find & jump** — a search field that finds matches within the currently open
   transcript and lets the user jump between them (like Cmd-F), keeping surrounding reading context.
2. **Long-press word lookup** — long-press a word (or drag to select a phrase) to bring up iOS's
   native selection menu (Look Up / Translate / Search Web / Copy / Share).

Both features live entirely within the existing `TranscriptView`. The existing behaviors —
tap-a-line-to-jump (read mode), the "Select" toolbar toggle for clip-range picking, playback
auto-follow, and word-level active highlighting — are preserved.

## Non-goals

- No changes to the global cross-show `TranscriptSearch` (FTS5). This feature searches only the one
  transcript already in memory.
- No custom dictionary / web-search UI. "Look Up" and "Search Web" are handled entirely by the iOS
  system selection menu.
- No model, schema, or networking changes.

## Feature 1 — In-panel find & jump

### Activation & layout
- A **magnifier** button joins the nav bar toolbar (`.topBarTrailing`), alongside the existing
  "Select" button. Tapping it toggles search on.
- When on, a **search bar** is pinned at the top of the panel. It uses the shared `BrutalSearchField`
  component (same as Library/Discover), plus:
  - a **match counter** rendered as `"<current> / <total>"` (e.g. `3 / 12`), showing `0 / 0` when
    the query is empty or has no matches;
  - **up/down chevron** buttons to move to the previous / next match.
- Closing search (the field's clear/X, or toggling the magnifier off) clears the query, the match
  list, and all search highlighting, and returns to plain read mode.

### Matching
- Case-insensitive substring match (`localizedCaseInsensitiveContains`) over the in-memory `cueVMs`
  array. No FTS — the transcript is already loaded in memory.
- Recomputed whenever `query` changes: produces `matchIndices: [Int]` (ordered cue indices that
  contain the query). `currentMatch` resets to `0` (first match) on each recompute.
- Empty/whitespace query ⇒ empty `matchIndices`, no highlighting.

### Highlighting
- Matched substrings within a matching line render in **accent color + bold**, built by `Text`
  concatenation (the same idiom already used by `styledCueText`). All occurrences within a line are
  highlighted, not just the first.
- The cue holding the **current** match additionally gets the `accentWash` row background so the
  active hit is visible at a glance (this reuses the existing row-background slot; when searching,
  the current-match wash takes the place of the active-playback wash).

### Jump / navigation
- Up/down chevrons decrement/increment `currentMatch`, wrapping around the ends of `matchIndices`.
- On any `currentMatch` change, scroll that cue index to `.center` via the existing
  `ScrollViewReader` proxy. These search-driven scrolls **always** fire — they bypass the
  playback auto-follow throttle (the `lastUserScrollAt` / `isFollowing` guard).

### Interaction with playback auto-follow
- While the search bar is open, playback auto-scroll is **suspended** so it doesn't fight the user's
  match navigation. When search is closed, auto-follow resumes its normal behavior.

## Feature 2 — Long-press word lookup (UITextView-backed cue text)

### Spike result (2026-07-18, iOS 26.3 simulator)

The originally-designed approach — SwiftUI `.textSelection(.enabled)` on the cue `Text` — was
spiked and **disproven**: on iOS, long-press on a selectable `Text` shows a whole-text
**Copy | Share…** menu only. There is no word-level selection, no Look Up, no Search Web. (Gesture
coexistence was fine: long-press did not conflict with tap-to-jump or scrolling.) The user approved
pivoting to a UITextView-backed approach, which is what apps like Apple Podcasts use for selectable
transcripts.

### Design

- In **read mode**, each cue's text renders through `SelectableCueText`, a `UIViewRepresentable`
  wrapping a non-editable, non-scrolling, selectable `UITextView`. This provides full native
  selection: long-press selects the word under the finger with drag handles, and the system edit
  menu offers **Look Up**, **Search Web**, **Translate**, **Copy**, **Share** — still no custom
  menu code.
- **Tap-to-jump** is preserved via a `UITapGestureRecognizer` on the text view that calls back into
  the row's jump action. If the text view has an active selection, a tap clears the selection
  instead of jumping (matching standard iOS behavior and preventing accidental jumps).
- **Styling** moves from `Text` concatenation to `NSAttributedString`, built by a small pure
  function that layers: base color (active vs. inactive cue) → active-word emphasis (existing
  behavior, on-device transcripts only) → search-match emphasis (accent + bold). Font comes from a
  `@ScaledMetric(relativeTo: .body)` size in the view so Dynamic Type (and the app-wide
  `.accessibility1` cap) keeps working.
- **Mode gating:** clip **Select mode** renders plain `Text` rows (no selection, no tap-to-jump
  conflict), exactly as today.

## Code shape

New files:
- `Onda/Transcription/TranscriptFind.swift` — pure match logic (mirrors the `ActiveCue` idiom):
  `matchingIndices(query:in:)` over the cue texts, and `segments(of:query:)` splitting one cue's
  text into match/non-match runs for highlight rendering. Unit-tested.
- `Onda/Player/SelectableCueText.swift` — the `UIViewRepresentable` UITextView wrapper (takes an
  `NSAttributedString` and an `onTap` closure), plus the attributed-string styler function.

Within `TranscriptView.swift` — new `@State`:
- `searching: Bool`
- `query: String`
- `matchIndices: [Int]`
- `currentMatch: Int`

New/changed pieces:
- **Read-mode cue text** renders via `SelectableCueText`; the attributed styler layers, in order:
  base color (active vs. inactive cue) → active-word emphasis (active cue only) → search-match
  emphasis (new). Select mode renders plain `Text(cue.text)`; the old `styledCueText` `Text`
  concatenation is retired.
- **`searchBar` view** — `BrutalSearchField` + counter + chevrons, shown when `searching` is true
  (top of panel).
- **Toolbar magnifier item** toggling `searching`.
- **Navigation helpers** — `recomputeMatches()` (on query change), `nextMatch()`,
  `prevMatch()`, and the `currentMatch`-change scroll effect.
- Suspend playback auto-follow while `searching`.

## Testing

- `TranscriptFind` (match indices, segment splitting, case-insensitivity, multiple occurrences,
  empty/whitespace queries) and the attributed styler (ranges, attributes) get unit tests in
  `OndaTests` (XCTest, matching `ActiveCueTests` style).
- The UI/gesture behavior is verified manually in the Simulator via the `verify` skill: word
  long-press → system menu with Look Up/Search Web, tap-to-jump still works, scroll unaffected,
  clip Select mode unaffected, search matching/counter/chevron wrap-around/current-match scroll/
  highlight rendering, auto-follow suspension while searching.
