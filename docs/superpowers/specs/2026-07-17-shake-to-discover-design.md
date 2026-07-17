# Shake to Discover — Design

**Date:** 2026-07-17
**Status:** Approved, ready for implementation planning

## Summary

On the Discover tab, physically shaking the phone refreshes the show list in place
with a random set of podcast suggestions drawn from the **categories of shows the user
already follows**. It is a playful, personalized rediscovery gesture — no new screen,
no modal. Shaking again reshuffles; a small "Back to Trending" chip returns to the
normal Trending list.

## Behavior

While the Discover tab is the visible tab, a shake:

1. Fires a haptic (medium impact) so the gesture feels acknowledged even before results load.
2. Selects **1–2 categories at random** from the distinct categories of the user's followed
   shows. If the user follows nothing, it falls back to a random pick from the built-in
   category list already used for the Discover chips
   (`Technology, Comedy, News, Business, Health, Science`).
3. Searches iTunes for each selected category, merges the results, **de-dupes across
   searches**, **removes shows the user already follows**, shuffles, and caps at ~20.
4. The Discover list animates/refreshes in place to these picks (the "full refresh" feel —
   no separate surface). The section header switches to a **rotating title** (see below)
   with a subtle subtitle naming the categories used, e.g. "Because you follow Technology
   & Comedy". In the no-follows fallback case the subtitle reads "A random mix by topic".
5. A small **"Back to Trending"** chip appears. Tapping it clears shake mode and restores
   the normal Trending list. Shaking again produces a fresh random set. Typing into the
   search field also exits shake mode (search always wins).

### Rotating header title

Each shake picks one of the following at random for the section header:

- "Shaken for you"
- "Look what rolled in"
- "New podcasts drifting in"

## Components & boundaries

### `ShakeDetector` — new, `Onda/Discover/ShakeDetector.swift`

A minimal UIKit bridge:

- A `UIWindow` subclass override of `motionEnded(_:with:)` that posts a
  `Notification` (e.g. `.deviceDidShake`) when the motion is `.motionShake`.
- An `.onShake { }` SwiftUI `View` modifier that subscribes to that notification via
  `onReceive`.

Only `DiscoverView` attaches `.onShake`, and `RootView` mounts tab bodies via a
`switch tab` (not a `TabView`), so `DiscoverView` is unmounted whenever another tab is
selected. This means shakes on Library/Profile are naturally ignored without any explicit
tab-selection gating.

Not unit-tested — UIKit motion delivery has no public test hook. Kept small and obvious.

### `DiscoverSuggestions` — new, `Onda/Discover/DiscoverSuggestions.swift`

The testable core. A pure async function with injected randomness and network:

```swift
func shakeSuggestions(
    followedCategories: [String],
    fallbackCategories: [String],
    subscribedFeeds: Set<URL>,
    using client: any Searching,
    rng: inout some RandomNumberGenerator
) async -> ShakeSuggestions
```

where `ShakeSuggestions` carries the resulting `picks: [PodcastDTO]` and the
`categories: [String]` that were used (for the subtitle).

Steps:

1. Choose the source set: `followedCategories` if non-empty, else `fallbackCategories`.
   Track whether the fallback was used (drives the subtitle wording).
2. Randomly select up to 2 distinct categories from the source using `rng`
   (if the source has only 1, use it).
3. `await client.search(term:)` for each selected category. A search that throws is
   skipped, not fatal.
4. Merge results, de-dupe by feed URL (falling back to `collectionId` when feed URL is
   nil), and remove any whose `feedUrl` is in `subscribedFeeds`.
5. Shuffle with `rng` and cap at the result limit (~20).

Randomness is injected via `rng` (defaults to `SystemRandomNumberGenerator` at the call
site) so unit tests are deterministic. Network is injected via the existing `Searching`
protocol.

### `DiscoverView` wiring — `Onda/Shell/DiscoverView.swift`

- New state: `@State private var shake: ShakeState?` where `nil` = normal mode and a
  non-nil value holds `{ picks: [PodcastDTO], categories: [String], usedFallback: Bool,
  title: String }`.
- `.onShake` handler: fire haptic, build the followed-category set from the `subs` query,
  call `shakeSuggestions(...)`, and assign `shake` inside `withAnimation` for the refresh
  transition. The title is drawn at random from the rotating set.
- List source becomes `shake?.picks ?? (results.isEmpty ? trending : results)`.
- Header: when `shake != nil`, show the rotating title plus the categories subtitle and
  the "Back to Trending" chip; otherwise the existing "Trending Today" / "Results" header.
- Search interaction: when the query becomes a non-empty search term, clear `shake`
  (search takes precedence).

## Data flow

`Podcast.category` (already populated from the iTunes `primaryGenreName` on subscribe)
→ distinct category set → `shakeSuggestions` → `client.search(term:)` per selected
category → de-duped / follow-filtered / shuffled `[PodcastDTO]` → `shake.picks` →
rendered by the existing `TrendingRow` list (unchanged).

## Error handling

- A failed category search is skipped; remaining categories still contribute.
- If every search fails or yields nothing new, shake mode still engages: the haptic fires,
  the header + "Back to Trending" chip show, and the list area is simply empty. The
  gesture is always acknowledged.

## Testing

Unit tests for `shakeSuggestions` using a stub `Searching` implementation and a seeded
deterministic `RandomNumberGenerator`:

- Uses followed categories when the user follows shows.
- Falls back to the built-in categories when the user follows nothing (and reports the
  fallback so the subtitle wording is correct).
- Filters out shows the user already follows (by feed URL).
- De-dupes shows that appear in more than one category search.
- Caps the result count at the limit.
- Skips a category whose search throws, without failing the whole operation.

The shake **gesture** itself is not covered by an automated UI test — XCUITest has no
public shake API — so it is verified by build + manual testing.

## Out of scope (YAGNI)

- App-wide shake (this is Discover-only by design).
- Persisting or "remembering" past shake results across launches.
- A dedicated shake settings/toggle.
- Weighting categories by how many shows the user follows in each (a simple uniform random
  pick is enough for v1).
