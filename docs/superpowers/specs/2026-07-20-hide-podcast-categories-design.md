# Hide podcast categories from suggestions

## Problem

Discover surfaces shows via genre/category signals (Trending, category browse chips, Shake,
For You recommendations, cold-start charts). There's no way to permanently exclude a whole
category you're never interested in (e.g. True Crime) — only individual shows, via the existing
`HiddenShows` "hide from Discover" feature.

## Scope

- Hide categories from **suggestion surfaces only**: Trending, category browse chips, Shake, and
  For You recommendations (including its cold-start top-charts fallback).
- Typed search results are **never** filtered by hidden categories — an explicit search is an
  explicit ask, regardless of category preference.
- Individually-subscribed shows are never touched, even if their category is hidden — this only
  affects what gets *suggested* going forward.
- Managed from a dedicated Settings screen (no swipe/context-menu entry point, unlike
  `HiddenShows` — see UI below).

## Data & storage

New `HiddenCategories` store, `Onda/Discover/HiddenCategories.swift` — same shape as the existing
`HiddenShows`/`DismissedShows`: `@MainActor @Observable`, backed by `UserDefaults` under key
`hiddenCategoriesList` (`Set<String>` of category names). Injected into the environment in
`OndaApp.swift`.

Owns the canonical list of Apple's top-level podcast categories (the picker's source of truth):

```
Arts, Business, Comedy, Education, Fiction, Government, History, Health & Fitness,
Kids & Family, Leisure, Music, News, Religion & Spirituality, Science, Society & Culture,
Sports, Technology, True Crime, TV & Film
```

This lets a category be pre-hidden even before it's ever appeared in the user's results.

`isHidden(_ dto: PodcastDTO) -> Bool` checks `dto.primaryGenreName` against the hidden set — the
same field `CandidateReranker`/`TasteProfile` already key genre matching on, so no new
normalization logic is introduced.

**Existing-code touch:** `DiscoverView`'s hardcoded quick-filter chip `"Health"` is renamed to
`"Health & Fitness"` to exactly match the canonical name, so chip removal (below) is a plain
string-equality check rather than fuzzy matching.

## Filtering integration points

- **Trending & Shake results** (`DiscoverView.listItems`): filtered by
  `hiddenCategories.isHidden(dto)`, alongside the existing per-show `hidden.isHidden(dto)` check —
  but only for the trending/shake item sources, never for typed-search `results`.
- **Category chips row**: chips are filtered to drop any chip whose name is in the hidden set — a
  hidden category simply has no chip to tap into.
- **`followedCategories`** (the category-name array fed into Shake's fallback pool and
  recommendations' cold-start/query generation, computed in `DiscoverView` from subscribed shows'
  `category`): hidden categories are excluded here too, so a hidden genre is never used to *seed*
  new suggestions, even from a subscription in that category.
- **For You recommendations** (`RecommendationService` → `CandidateRetriever.retrieve` /
  `RecommendationService.charts`): both gain an `isCategoryHidden: (PodcastDTO) -> Bool` closure
  parameter, alongside the existing `isDismissed` closure, so hidden-category shows never enter
  the candidate pool.
- **`shakeSuggestions`** (`DiscoverSuggestions.swift`): gains the same `isCategoryHidden` closure,
  applied during its existing dedup/filter pass.

## Settings UI

New `HiddenCategoriesView.swift` in `Onda/Profile/`, linked from `ProfileView` directly below
"Hidden Podcasts". Unlike `HiddenPodcastsView` (which only *unhides* — hiding happens via swipe in
Discover), this screen has no external hide entry point, so it doubles as the picker: a checklist
of all ~19 canonical categories, sorted alphabetically, each row toggling hidden/shown directly on
tap (checkmark = hidden, visually consistent with the existing `categoryChips` selected state). A
caption explains scope: "Hidden from Trending, category browsing, Shake, and For You. Search
results aren't affected."

## Testing

- `HiddenCategoriesTests.swift` (mirrors `HiddenShowsTests`): persistence round-trip,
  `isHidden(dto:)` matching on `primaryGenreName`, toggle behavior.
- `DiscoverSuggestionsTests`: updated for the new `isCategoryHidden` param on `shakeSuggestions`.
- `RecommendationPipelineTests` / `RecommendationScoringTests`: updated for the new exclusion in
  `CandidateRetriever.retrieve` / `RecommendationService.charts`.
- A test (unit-level if the chip-filter logic is easily extracted, otherwise covered via the
  `HiddenCategories` tests) confirming a hidden category's chip is excluded from the row.
