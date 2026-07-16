# Onda — iOS Podcast App: Design

## Summary

Onda is a personal podcast-listening app for iOS (SwiftUI, iOS 17+, SwiftData). v1 is single-user,
no backend of our own — podcast discovery comes from Apple's iTunes Search API, episode/chapter
metadata and audio come directly from each show's own RSS feed (parsed client-side). Visual/interaction
design is already established via an imported Claude Design prototype
(`Podcast App.dc.html`, project `1310b975-5d75-42ee-a464-29f8adb3c925`): a neo-brutalist style
(thick borders, hard drop shadows, sharp corners, uppercase Arial Black headers) with light/dark
theming.

## Scope (v1)

- Search/subscribe to podcasts, browse by category/trending
- Per-show episode lists, playback (stream or downloaded)
- Playback: variable speed, sleep timer, skip-silence, voice boost, cross-show manual queue
- Per-show settings: speed, voice boost, skip silence, ad-skip mode, auto-download, intro/outro
  trim, notification preference
- Episode downloads for offline playback
- Light/dark appearance

Out of scope for v1: multi-device sync, backend of our own, social features, real ad-detection
beyond Podcasting 2.0 chapter markers.

## Screens & Navigation

- **Tab bar**: Library, Discover, Profile
- **Library** — 2-column grid of subscribed shows → tap → **Episode List**
- **Episode List** *(new — not in the original prototype, which jumped straight to playback)* —
  show header (art, name, category, unsubscribe) + episode rows (title, date, duration,
  played/in-progress indicator, download control) → tap episode → **Now Playing**
- **Discover** — search bar (iTunes Search by-term), category chips, trending list with
  Follow button (trending sourced from iTunes' charts endpoint per-category)
- **Now Playing** — artwork, title/show, scrubber, skip ±15/30, play/pause, Speed/Voice
  Boost/Skip-Silence chips, ad banner (only rendered when the current episode has a real
  Podcasting-2.0 ad-marked chapter active — no simulated/timer-based ads), Chapters list, About
  This Episode notes, **+ Up Next queue** *(new)* reachable via a queue icon/swipe — cross-show
  manual queue, reorderable, tap to jump
- **Per-show settings sheet** — Speed, Voice Boost, Skip Silence, Ad Skip mode, Auto-Download,
  Skip Intro/Outro trim (±5s steps), Notification preference (All/Important/None)
- **Profile** — Appearance toggle (light/dark), Notifications, **Downloads & Storage** *(new —
  actual manager screen, not just a settings row)*: downloaded episodes list, storage used,
  delete, About

Visual style (borders, hard shadows, sharp corners, typography, oklch-based light/dark palette)
carries over from the prototype as the source of truth; new screens (Episode List, Up Next queue,
Downloads & Storage) are designed to match that visual language.

## Architecture

Plain SwiftUI "MV" pattern: `@Observable` model/service classes, no separate ViewModel layer.
Views read directly from SwiftData `@Query` and `@Observable` service singletons injected via
the environment.

## Data Model (SwiftData)

```
@Model Podcast        — feedURL, title, author, artworkURL, category, itunesId
@Model Episode        — belongs to Podcast; guid, title, publishDate, duration, audioURL,
                         notes (HTML→plain), playbackPosition, played: Bool
@Model Chapter        — belongs to Episode; title, startTime, isAd: Bool
                         (derived from a Podcasting 2.0 `<podcast:chapters>` JSON link when the
                         feed publishes one)
@Model ShowSettings   — 1:1 with Podcast; speed, voiceBoost, skipSilence, adSkipMode,
                         autoDownload, introTrimSec, outroTrimSec, notifMode
                         (created lazily with defaults on first subscribe / first settings open)
@Model QueueItem      — ordered list; references Episode, position: Int
@Model DownloadedFile — 1:1 with Episode; localFileURL, fileSizeBytes, downloadedAt
```

`Episode.playbackPosition` is persisted every ~5s during playback so resume works across app
launches; `played` flips true past ~95% listened.

## Services

- **`ITunesSearchClient`** — async/await wrapper over Apple's public iTunes Search API
  (`itunes.apple.com/search?media=podcast`, `.../lookup`, and the charts/RSS-generator feed for
  trending-by-category). No API key or account needed. Returns each show's `feedUrl`, which is
  the handoff point into `RSSFeedParser`. Unofficial/undocumented — no SLA — so calls are
  defensive (timeouts, tolerant JSON decoding) rather than assuming a stable contract.
- **`RSSFeedParser`** — `XMLParser`-based client-side parser for a show's own RSS feed: episode
  list (title, guid, publish date, duration, enclosure/audioURL, show notes), plus optional
  Podcasting 2.0 tags (`<podcast:chapters>` JSON link for chapters/ad-markers,
  `<podcast:transcript>` if present later). This is now the *only* source of episode data — it
  replaces what PodcastIndex used to aggregate, so it must tolerate the real-world messiness of
  hand-rolled feeds (missing/malformed dates, missing enclosure length, non-standard namespaces).
- **`FeedRefreshService`** — re-fetches each subscribed show's feed via `RSSFeedParser` on app
  foreground + a background refresh task; upserts new `Episode` rows; triggers auto-download for
  shows with `autoDownload = true`.
- **`PlaybackManager`** (`@Observable`) — wraps `AVPlayer`:
  - Plays from `DownloadedFile.localFileURL` when present, else streams `Episode.audioURL`
  - Applies per-show `speed` via `AVPlayer.rate`; applies `introTrimSec`/`outroTrimSec` via
    seek-on-start / stop-before-end
  - Voice Boost / Skip Silence via an `AVAudioEngine` tap chain (dynamics processor for boost;
    energy-threshold detection + time-compression for silence skip) — highest-complexity,
    highest-risk piece of v1
  - Publishes now-playing info to `MPNowPlayingInfoCenter`; wires `MPRemoteCommandCenter` for
    lock screen / Control Center / AirPods controls
  - Owns the `QueueItem` list; on episode end, advances to the next queue item, else next
    unplayed episode in the same show
- **`DownloadManager`** — `URLSession` background-configuration download tasks per episode;
  publishes per-episode progress; deletes `DownloadedFile` row + on-disk file together.

## Error Handling

- SwiftData is the source of truth for what's rendered; network only refreshes it — search/refresh
  failures show inline retry state, never blank screens
- Streaming playback failure (no local file + bad network) surfaces a toast (reusing the
  prototype's toast component), not a crash
- Failed background downloads retry once automatically, then show a manual-retry affordance in
  Downloads & Storage
- `AVAudioSession` category `.playback` configured at launch so audio continues when
  backgrounded/screen-locked

## Testing

- Unit tests: `ITunesSearchClient` response decoding and `RSSFeedParser` XML parsing against
  fixture JSON/RSS (including malformed/real-world feed samples) — no live network in tests
- Unit tests: `PlaybackManager` trim/queue-advance logic against a fake player protocol
- SwiftData model tests (in-memory container): subscribe/unsubscribe, settings defaults, queue
  reordering
- No UI snapshot tests for v1 — the prototype is the visual source of truth; manual verification
  against it is sufficient at this stage

## Open Risks

- **Voice Boost / Skip Silence via `AVAudioEngine`** is genuinely complex DSP work; may need to
  descope to a simpler implementation (e.g. boost = static gain node only, no dynamic silence
  detection) if it proves too costly during implementation
- **Ad-skip only fires for feeds with real Podcasting 2.0 ad-marked chapters**, which are rare in
  practice — the feature may rarely activate; that's an accepted v1 tradeoff over faking it
- **iTunes Search API is unofficial/undocumented** with no SLA — acceptable for a personal v1, but
  a risk if usage grows; PodcastIndex remains the preferred fallback if signups reopen
- **Client-side RSS parsing (`RSSFeedParser`) must handle messy real-world feeds** (malformed
  dates, missing fields, nonstandard namespaces) that PodcastIndex would otherwise have normalized
  for us — expect to harden this incrementally against real shows during implementation
