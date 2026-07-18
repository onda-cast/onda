# Private Feed Tokens in Keychain — Design

Date: 2026-07-18
Status: Approved

## Goal

Private/paid feeds (see `docs/superpowers/specs/2026-07-17-private-podcast-feeds-design.md`)
store their tokenized RSS URL in `Podcast.feedURL`, a plain SwiftData field. SwiftData's store
gets iOS's default file protection (`NSFileProtectionCompleteUntilFirstUserAuthentication`), but
the token still sits in plaintext in the on-disk SQLite file, included in device/iCloud backups,
readable by anything with disk access after first unlock. This moves the token itself into
Keychain, which is iOS's dedicated secret store, while keeping `Podcast.feedURL` as the stable
SwiftData identity key.

Out of scope: `Episode.audioURL`/`chaptersURL`/`transcriptURL` (may carry their own per-host
tokens for some private-feed providers, but that's a separate, larger change — noted as a
follow-up); downloaded audio file protection; excluding downloads from backup.

## Data model

`Podcast.feedURL` keeps its type (`URL`, `@Attribute(.unique)`) and keeps holding the real URL
for public (iTunes-sourced) podcasts, unchanged.

For `isPrivateFeed == true` podcasts, `feedURL` instead holds a synthetic placeholder:

```
onda-private-feed://<sha256-hex-of-real-url>
```

This keeps every existing call site that treats `feedURL` as an opaque identity/equality key —
`DiscoverView`'s subscribed-set, `RecommendationService`, `StorageBreakdown`/
`DownloadsStorageView` row IDs, the SwiftData uniqueness constraint, `existingPodcast(feedURL:)`
dedup — working unchanged, since the placeholder is still a valid, stable, unique `URL`. None of
those call sites need the real URL; they only need something stable to key off, and `feedURL` is
never rendered as text anywhere in the UI today.

The real, tokenized URL lives only in Keychain, keyed by the same SHA-256 hash.

## New: `PrivateFeedIdentity`

Free function shared by the token store and the placeholder-URL constructor:

```swift
enum PrivateFeedIdentity {
    static func hash(for url: URL) -> String   // SHA-256 (CryptoKit), hex-encoded
    static func placeholderURL(forHash hash: String) -> URL
}
```

## New: `PrivateFeedTokenStore`

`Onda/Services/PrivateFeedTokenStore.swift`, a plain class (no `@Observable` needed — it's a
narrow read/write utility, not view state), wrapping Keychain via the Security framework:

```swift
protocol PrivateFeedTokenStoring {
    func store(realURL: URL, hash: String) throws
    func realURL(forHash hash: String) throws -> URL?
    func delete(hash: String) throws
}
```

Keychain item attributes: `kSecClassGenericPassword`, account = `hash`, value = real URL's
`absoluteString` data, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`,
`kSecAttrSynchronizable = true` (syncs via iCloud Keychain across the user's own devices —
available to background feed refresh once the device has been unlocked once since boot).

Wired in `OndaApp.swift` alongside the other services and injected into `SubscriptionService`.

## Service layer changes (`SubscriptionService`)

- **`subscribeToFeedURL(_:)`**: unchanged input (still the real URL typed into AddFeedSheet).
  Computes `hash = PrivateFeedIdentity.hash(for: url)` up front; `existingPodcast` dedup now
  looks up by the *placeholder* URL built from that hash (so re-adding the same real URL is
  still recognized as a duplicate). On creating a new `Podcast`, writes `(url, hash)` to
  `PrivateFeedTokenStore` *before* constructing the row, and constructs it with the placeholder
  URL, not the real one. If the Keychain write fails, the subscribe throws and nothing is
  persisted (matches the existing "nothing persisted on failure" behavior for fetch failures).
- **`refreshEpisodes(for:)`**: resolves the fetch URL before calling `feeds.fetchFeed`:
  ```swift
  let fetchURL = podcast.isPrivateFeed
      ? try tokenStore.realURL(forHash: podcast.feedURL.host!) ?? { throw MissingTokenError() }()
      : podcast.feedURL
  ```
  A missing token (Keychain entry absent — e.g. restored from a backup that predates this
  change, or iCloud Keychain disabled/out of sync) throws rather than fetching the placeholder
  URL, which would just 404. This surfaces through the same paths that already handle
  refresh failures (silent in background `FeedRefreshService`, surfaced error in manual
  pull-to-refresh) — no new UI needed.

`FeedRefreshService` itself needs no changes — it already just calls
`subscriptions.refreshEpisodes(for:)` per podcast.

## Migration

`Onda/Services/PrivateFeedTokenMigration.swift`, run once at launch from `OndaApp` during
`ModelContainer` setup, before any UI is shown:

1. Fetch all `Podcast` where `isPrivateFeed == true`.
2. For any whose `feedURL.scheme != "onda-private-feed"` (i.e. still holding the real URL —
   not yet migrated): compute the hash from the current `feedURL`, write `(feedURL, hash)` to
   `PrivateFeedTokenStore`, then rewrite `podcast.feedURL` to the placeholder form.
3. One `modelContext.save()` after the pass.

**Fail-safe**: if a Keychain write fails for a given podcast, that podcast's `feedURL` is left
untouched (still the real URL) — it's simply retried on the next launch. No partial-migration
state is possible per podcast (the `feedURL` rewrite only happens after the Keychain write
succeeds), and no data is lost either way.

**Idempotent**: already-migrated podcasts (`feedURL.scheme == "onda-private-feed"`) are skipped,
so running migration on every launch is safe and cheap (no-op after the first successful run).

## Out of scope / accepted gaps

- **No Keychain cleanup on unsubscribe**: `SubscriptionService.unsubscribe(_:)` only flips
  `isSubscribed = false` and frees downloads/transcripts — it never hard-deletes the `Podcast`
  row (confirmed: no `modelContext.delete(Podcast...)` call exists anywhere today). The Keychain
  entry's lifetime already matches the `Podcast` row's lifetime as a result; no extra cleanup
  logic is needed unless a future "remove from library" hard-delete feature is added, at which
  point it should also call `tokenStore.delete(hash:)`.
- **Episode-level URLs**: not covered by this change (see Goal).

## Testing

Unit tests (stubbing `FeedFetching` as existing tests do, plus a fake/in-memory
`PrivateFeedTokenStoring` for service-layer tests and real-Keychain round-trip tests for the
store itself):

- `PrivateFeedIdentity.hash`: deterministic for the same URL; different for different URLs.
- `PrivateFeedTokenStore`: store → `realURL(forHash:)` returns what was stored; delete →
  `realURL(forHash:)` returns `nil`. Uses a distinct Keychain service/account namespace so tests
  don't collide with real app data.
- `subscribeToFeedURL`: new private podcast gets a placeholder `feedURL`; the real URL lands in
  the token store; re-subscribing the same real URL resolves to the existing row (no duplicate
  `Podcast`, no duplicate Keychain write).
- `refreshEpisodes`: for a private podcast, `feeds.fetchFeed` is called with the *resolved real
  URL*, not the placeholder; for a public podcast, behavior is unchanged (fetches `feedURL`
  directly, no token store interaction).
- `refreshEpisodes` missing-token case: mock the token store to return `nil` for a private
  podcast's hash; assert the call throws instead of fetching the placeholder URL.
- Migration: seed a `Podcast` with `isPrivateFeed = true` and a real `feedURL`; run migration;
  assert `feedURL` is now the placeholder form and the token store holds the original real URL.
  Running migration twice is a no-op the second time (already-migrated rows are skipped).
