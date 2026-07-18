# Private Podcast Feeds (Add by URL) — Design

Date: 2026-07-17
Status: Approved

## Goal

Let the user subscribe to private/paid podcast feeds — the tokenized-URL kind (Patreon,
Supercast, Memberful, Substack, etc.), where the subscription service issues a unique secret
RSS URL per member. No HTTP authentication support: the token lives in the URL, so the
existing unauthenticated fetch path works unchanged for feed refresh, artwork, downloads,
and streaming.

Out of scope: HTTP Basic Auth feeds, credential storage, OPML import.

## Data model

`Podcast` gains one property:

```swift
var isPrivateFeed: Bool = false
```

SwiftData lightweight-migrates the added property via its default value. No other schema
changes — the tokenized URL is simply `feedURL`, unique as today.

## Service layer

New method on `SubscriptionService`:

```swift
@discardableResult
func subscribeToFeedURL(_ url: URL) async throws -> Podcast
```

Behavior:

1. `feeds.fetchFeed(url)` — throws a user-readable error if the URL is unreachable or not
   parseable RSS. Nothing is persisted on failure.
2. Dedupe on `feedURL` using the existing `existingPodcast(feedURL:)` check. Re-adding an
   already-known feed resubscribes the existing row (sets `isSubscribed = true`) instead of
   duplicating.
3. Otherwise create a `Podcast` from the `ParsedFeed` channel metadata (title, author,
   artwork URL, category), with `itunesId: nil` and `isPrivateFeed: true`.
4. Shared subscribe tail, factored into a private helper used by both `subscribe(to:)` and
   `subscribeToFeedURL(_:)` so the two paths cannot drift: ensure `ShowSettings` exists,
   `refreshEpisodes(for:)`, save, auto-download the newest episode.

`FeedRefreshService` needs no changes — private podcasts refresh exactly like public ones.

## UI (Discover tab)

- A link-icon button next to the Discover search field opens **AddFeedSheet**.
- AddFeedSheet: URL text field, pre-filled from the clipboard when the clipboard holds an
  http(s) URL; a Fetch action; then a preview card (artwork, title, author, episode count)
  with a Subscribe button.
- Errors show inline in the sheet ("Couldn't load this feed — check that the URL is correct
  and your membership is active"). Nothing is persisted until Subscribe succeeds.
- Styled with the existing neo-brutalist Theme components; controls meet the ≥44pt tap
  target and VoiceOver-label conventions established in the UX pass.

## Privacy handling

- Library `ShowCard` shows a small "PRIVATE" badge for `isPrivateFeed` shows.
- `TasteProfile` skips `isPrivateFeed` podcasts entirely — their titles, categories, and
  episode titles never contribute to iTunes search terms sent to Apple.
- No current share surface exposes feed URLs (only clip audio is shared). The flag exists
  as the guard for any future share/export feature.
- Unsubscribe behaves exactly as for public shows.

## Error handling

- Add-time fetch failures: inline sheet error; no rows inserted.
- Post-subscribe refresh failures (e.g. revoked token): `FeedRefreshService` already
  tolerates per-feed failures silently; no new UX now. A "feed unreachable" badge can be
  added later if it proves to be a real annoyance.

## Testing

Unit tests (stubbing via the existing `FeedFetching` protocol):

- Happy path: podcast created from channel metadata, `isPrivateFeed == true`, episodes
  inserted, settings created.
- Dedupe: re-adding the same URL resubscribes the existing podcast; no duplicate row.
- Fetch failure: `subscribeToFeedURL` throws and nothing is persisted.
- Public path unchanged: `subscribe(to:)` still yields `isPrivateFeed == false`.
- `TasteProfile`: private shows contribute nothing to the profile.
