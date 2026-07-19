# Transcript UI: in-panel search & word lookup

**Date:** 2026-07-18
**Status:** Approved design, ready for implementation plan
**Scope:** `Onda/Player/TranscriptView.swift` only. No model/schema changes, no new files, no networking.

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

## Feature 2 — Long-press word lookup (Option A: native text selection)

- Cue text becomes natively selectable via `.textSelection(.enabled)`. Long-press selects the word
  under the finger; dragging extends the selection to a phrase. iOS then presents its own menu with
  **Look Up**, **Translate**, **Search Web**, **Copy**, **Share** — no custom menu code.
- **Gesture coexistence:** tap (jump-to-player) and long-press (selection) are distinct recognizers,
  so both remain on the row in read mode.
- **Mode gating:** text selection is enabled only in **read mode**. Entering the existing clip
  **Select mode** disables selection so long-press does not fight clip range-tapping.

### Verification-first risk

The primary implementation risk is whether SwiftUI allows a `Text` to be selectable while its
enclosing row keeps tap-to-jump *and* the surrounding `ScrollView` keeps scrolling. This must be
proven in the Simulator **before** building out the rest of the feature (use the `verify` skill).

Fallback ladder if the naïve `.textSelection(.enabled)` on the cue `Text` fights the row's tap or
scroll:
1. Attach `.textSelection(.enabled)` at the enclosing `VStack` level instead of the raw `Text`.
2. Tighten gating (e.g. selection only when not actively following playback).
3. If irreconcilable, revisit with the user (e.g. move jump entirely to the per-row play button so
   tap is freed for selection — Option C from brainstorming).

## Code shape (all within `TranscriptView.swift`)

New `@State`:
- `searching: Bool`
- `query: String`
- `matchIndices: [Int]`
- `currentMatch: Int`

New/changed pieces:
- **Unified cue-text builder** that layers, in order: base color (active vs. inactive cue) →
  active-word emphasis (existing behavior, active cue only) → search-match emphasis (new). Returns a
  single `Text`. This replaces/extends the current `styledCueText`.
- **`searchBar` view** — `BrutalSearchField` + counter + chevrons, shown when `searching` is true
  (top of panel).
- **Toolbar magnifier item** toggling `searching`.
- **Navigation helpers** — `recomputeMatches()` (on query change), `nextMatch()`,
  `prevMatch()`, and the `currentMatch`-change scroll effect.
- **`.textSelection(.enabled)`** on the cue text, gated to read mode (disabled while `selecting`).
- Suspend playback auto-follow while `searching`.

## Testing

- Because the change is UI/gesture-heavy in SwiftUI, primary verification is manual in the Simulator
  via the `verify` skill: prove text-selection coexistence first, then exercise search matching,
  counter, chevron wrap-around, current-match scroll, highlight rendering, and mode gating.
- Any pure-logic helpers that are cleanly extractable (e.g. match-index computation for a given query
  over a `[CueVM]`, chevron wrap-around arithmetic) should get lightweight unit tests in
  `OndaTests` if extracting them doesn't distort the view code.
