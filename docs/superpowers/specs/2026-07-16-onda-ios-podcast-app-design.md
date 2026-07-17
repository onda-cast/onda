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
- Transcripts: follow-along transcript view (doubles as captions), full-text transcript search —
  sourced from published Podcasting 2.0 transcripts first, on-device Apple Speech transcription as
  an iOS 26+ fallback

Out of scope for v1: multi-device sync, backend of our own, social features, real ad-detection
beyond Podcasting 2.0 chapter markers, transcript-based chapter/ad inference (unreliable;
Podcasting 2.0 markers already cover ads), on-device transcription below iOS 26.

## Screens & Navigation

- **Tab bar**: Library, Discover, Profile
- **Library** — 2-column grid of subscribed shows → tap → **Episode List**
- **Episode List** *(new — not in the original prototype, which jumped straight to playback)* —
  show header (art, name, category, unsubscribe) + episode rows (title, date, duration,
  played/in-progress indicator, download control) → tap episode → **Now Playing**
- **Discover** — search bar (iTunes Search by-term), category chips, trending list with
  Follow button (trending resolved per-category via `ITunesSearchClient`'s two-hop charts path —
  see Services)
- **Now Playing** — artwork, title/show, scrubber, skip ±15/30, play/pause, Speed/Voice
  Boost/Skip-Silence chips, **sleep-timer action** *(new — moon/timer icon near the chips;
  opens a menu: 5/10/15/30/45 min, "End of episode", Off)*, ad banner (only rendered when the
  current episode has a real Podcasting-2.0 ad-marked chapter active — no simulated/timer-based
  ads), Chapters list, About This Episode notes, **+ Up Next queue** *(new)* reachable via a
  queue icon/swipe — cross-show manual queue, reorderable, tap to jump, **+ Transcript view**
  *(new)* — scrollable time-aligned cues with the active cue highlighted + auto-scrolling, tap a
  cue to seek; doubles as captions/accessibility. When no transcript exists, shows a "Transcribe
  episode" affordance (iOS 26+, downloaded episodes only) or a "not available" message
- **Library search** — *(new)* transcript full-text search across subscribed shows; a hit jumps
  to the matching moment in the episode
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
@Model Transcript     — 1:1 with Episode; source ("published"|"ondevice"), language, cues: [TranscriptCue]
@Model TranscriptCue  — belongs to Transcript; startTime, endTime (feed-seconds), text, speaker: String?
```

`Episode` also carries `transcriptURL: URL?` and `transcriptType: String?`, captured from the
feed's `<podcast:transcript>` tag. `TranscriptCue` times are in feed-seconds, so follow-along
highlighting and tap-to-seek reuse the canonical-timeline position math.

`Episode.playbackPosition` is persisted every ~5s during playback so resume works across app
launches; `played` flips true past ~95% listened.

**Canonical timeline.** `playbackPosition`, `Chapter.startTime`, the scrubber, and all seeks are
always expressed in **original feed seconds**. Intro/outro trim and skip-silence are playback-layer
effects (they change what wall-clock time gets you to a given feed second) but never change the
stored/displayed timeline — position math stays in feed-time so resume, chapters, and the scrubber
stay consistent regardless of active effects.

## Services

- **`ITunesSearchClient`** — async/await wrapper over Apple's public iTunes Search API. No API key
  or account needed. Three call shapes:
  - **Search**: `itunes.apple.com/search?media=podcast&term=…` → shows with `feedUrl`
  - **Lookup**: `itunes.apple.com/lookup?id=…` → resolve a chart entry's iTunes ID to its `feedUrl`
  - **Trending by category** *(two hops — there is no single "trending by category" endpoint)*:
    the Marketing Tools RSS generator (`rss.marketingtools.apple.com/.../podcasts/top/…`) returns
    top-podcast **iTunes IDs** per genre → batch `/lookup` those IDs to get `feedUrl`s. The two-step
    is explicit here so it isn't a surprise during implementation.

  `feedUrl` is the handoff point into `RSSFeedParser`. Unofficial/undocumented — no SLA — so calls
  are defensive (timeouts, tolerant JSON decoding) rather than assuming a stable contract.
- **`RSSFeedParser`** — `XMLParser`-based client-side parser for a show's own RSS feed: episode
  list (title, guid, publish date, duration, enclosure/audioURL, show notes), plus optional
  Podcasting 2.0 tags (`<podcast:chapters>` JSON link for chapters/ad-markers,
  `<podcast:transcript>` if present later). This is now the *only* source of episode data — it
  replaces what PodcastIndex used to aggregate, so it must tolerate the real-world messiness of
  hand-rolled feeds (missing/malformed dates, missing enclosure length, non-standard namespaces).
- **`FeedRefreshService`** — re-fetches each subscribed show's feed via `RSSFeedParser` on app
  foreground + a background refresh task; upserts new `Episode` rows; triggers auto-download for
  shows with `autoDownload = true`.
- **`PlaybackManager`** (`@Observable`) — wraps `AVPlayer` (chosen over `AVAudioEngine` for its
  network streaming, range-download, and `AVPlayerItem` support):
  - Plays from `DownloadedFile.localFileURL` when present, else streams `Episode.audioURL`
  - Applies per-show `speed` via `AVPlayer.rate`; applies `introTrimSec`/`outroTrimSec` via
    seek-on-start / stop-before-end (in feed-time — see Canonical timeline above)
  - **Real-time audio DSP via `MTAudioProcessingTap`** attached to the `AVPlayerItem`'s
    `audioMix` (this is the correct way to tap `AVPlayer` audio — `AVAudioEngine` is a separate,
    incompatible playback path and is *not* used):
    - **Voice Boost** — gain/dynamics applied inside the tap's process callback (low risk)
    - **Skip Silence** — the tap's process callback runs a rolling energy analysis on PCM
      buffers; sustained sub-threshold energy triggers an `AVPlayer` seek to jump the quiet
      span. **Highest-complexity, highest-risk piece of v1** — buffering latency means detection
      and the resulting seek are inherently coarse; accept some imprecision. Kept in v1 scope.
  - **Sleep timer** — a duration-based timer (5/10/15/30/45 min) or an "end of episode" mode that
    pauses playback when it fires; surfaced via the Now Playing sleep-timer action
  - Publishes now-playing info to `MPNowPlayingInfoCenter`; wires `MPRemoteCommandCenter` for
    lock screen / Control Center / AirPods controls
  - Owns the `QueueItem` list; on episode end, advances to the next queue item, else next
    unplayed episode in the same show
- **`DownloadManager`** — `URLSession` background-configuration download tasks per episode;
  publishes per-episode progress; deletes `DownloadedFile` row + on-disk file together. Background
  completions arrive on a system queue via the app-delegate handler, so the resulting SwiftData
  writes hop to a dedicated `@ModelActor` context rather than touching a view context off-thread.
- **`ArtworkCache`** — disk-backed image cache for show/episode artwork (grids and lists re-render
  during scroll, so raw `AsyncImage` would refetch); a lightweight `URLCache`-backed loader or
  small on-disk LRU, exposed as a SwiftUI image view used everywhere artwork appears.
- **`TranscriptParser`** — pure parser turning a published transcript (Podcasting 2.0 JSON, WebVTT,
  or SRT) into time-aligned `[ParsedCue]`. Tolerant of format quirks like `RSSFeedParser`.
- **`SpeechTranscriberEngine`** (`@available(iOS 26)`, behind an `AudioTranscribing` protocol) —
  on-device Apple Speech (`SpeechAnalyzer`/`SpeechTranscriber`) transcription of a downloaded audio
  file into time-aligned cues, with progress. Gated to iOS 26+; the protocol keeps it stubbable in
  tests and cleanly absent on older OSes.
- **`TranscriptService`** (`@Observable`) — `transcript(for:)`: if the episode has a published
  `transcriptURL`, fetch + `TranscriptParser` + persist (`source = "published"`); else on iOS 26+
  with the episode downloaded, run `SpeechTranscriberEngine` (`source = "ondevice"`); else none.
  Fetching is **on-demand** (first time the transcript view opens), then cached. Owns Speech
  authorization (`NSSpeechRecognitionUsageDescription`).
- **`TranscriptSearch`** — full-text query over persisted `TranscriptCue.text` (SwiftData
  predicate) across subscribed shows → hits (episode + cue + feed-second timestamp); backs Library
  search.

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
- Unit tests: `PlaybackManager` trim/queue-advance/sleep-timer logic against a fake player
  protocol; energy-threshold silence-detection logic tested against synthetic PCM buffers
  (loud/quiet fixtures) independent of live `AVPlayer`
- Unit tests: `TranscriptParser` against VTT/SRT/PC2.0-JSON fixtures (incl. malformed cues);
  active-cue selection logic against a synthetic cue list + position; `TranscriptSearch` matching
  against an in-memory container. `SpeechTranscriberEngine` is exercised behind its protocol with a
  stub — no real Speech recognition in tests.
- SwiftData model tests (in-memory container): subscribe/unsubscribe, settings defaults, queue
  reordering
- No UI snapshot tests for v1 — the prototype is the visual source of truth; manual verification
  against it is sufficient at this stage

## v0.3 Addendum — Clips & Capture (added 2026-07-16, post-v0.2.0)

**Niche statement.** Onda's differentiation vs. the 2026 field (Apple/Overcast/Pocket Casts all
ship read-along transcripts; Snipd owns cloud-AI capture at $9.99/mo): **knowledge capture that
is on-device, private, and free** — transcripts (published-first + on-device), library-wide
transcript search, and now *clips*: cue-range excerpts with notes, captured even from the lock
screen. No servers, no subscription, exports are the user's data.

**Scope (v0.3):**
- **Clips** — a saved range of an episode (feed-seconds start/end) with the transcript text for
  that range snapshotted at creation, plus an optional user note. Created two ways:
  - *Transcript selection*: in the transcript view, a selection mode turns cue taps into a range;
    confirm → clip sheet (range preview + note field).
  - *Lock-screen capture*: `MPRemoteCommandCenter.bookmarkCommand` while playing creates a
    **quick clip** of the trailing ~45 s (snapped to cue boundaries when a transcript exists),
    marked `needsReview` for later titling/trimming. Signature gesture of the niche.
- **Clips library** — a screen reachable from Library (bookmark icon beside search): all clips
  across shows, newest-first, text search (reuses the search machinery), tap → play just the
  clip (playback stops at clip end), swipe-to-delete, edit note.
- **Clip playback** — `PlaybackManager` plays a bounded range; the clip end behaves like an
  outro trim (stop, do not auto-advance).

**Data model addition:**
```
@Model Clip — belongs to Episode; startTime, endTime (feed-seconds), text (snapshot of cues in
              range, may be empty when no transcript existed), note: String?, createdAt: Date,
              needsReview: Bool (true for lock-screen quick clips until edited)
```

**v0.4 — Audio-snippet sharing (scoped 2026-07-16):** sharing a clip exports its audio range as
an **.m4a** (`AVAssetExportSession`, local file preferred, streaming asset fallback) and presents
the system share sheet with the file plus share text: quoted transcript excerpt (truncated
~300 chars) + `— Episode, Show @ m:ss`. The user's private note is **never** included. Service:
`ClipExporter` (async `export(clip:) -> URL`, pure `shareText(for:)`). Entry point: share button
on `ClipRow`. Video cards with waveform/captions remain deferred.

**v0.5 — Markdown export (shipped):** per-clip "Copy as Markdown" (context menu) and bulk "Export All" (.md via share sheet), grouped show → episode; personal export, so notes ARE included (unlike audio sharing). **Deferred (v0.6 candidates):** video share cards;
Readwise/Obsidian-style bulk export.

**Constraints carried forward:** feed-seconds canonical timeline; no cloud services; clip text is
a *snapshot* (later transcript improvements don't rewrite existing clips); prototype visual
language.

**Coordination note:** bug #1 (on-device transcribe crash) was root-caused in a parallel session
— MainActor-inherited completion handed to TCC; fix = `nonisolated` helper + `@Sendable`
completion (see memory + docs/BUGS.md). If that fix isn't merged when v0.3 work starts, apply it
and re-enable the Transcribe button as part of Plan 7.

## v0.6 Addendum — Smart Queues, Word Highlighting, AI Auto-Chapters, Full-Library Search (added 2026-07-16, post-v0.5)

**Context.** A 2026 competitive pass (Apple Podcasts, Spotify, Overcast, Pocket Casts, Snipd, Castro,
Podcast Addict/CastBox) found every competitor's best capture/search/organization features are
paywalled or require a cloud/AI backend (Pocket Casts gates transcripts behind Plus/Patron; Snipd
throttles free AI clipping to ~2 episodes/week). Onda already ships transcripts, search, and
clipping free with no backend — reaffirming the v0.3 niche (on-device, private, knowledge capture,
no cloud tether). This addendum closes the two gaps identified as worth closing without
compromising that identity — smart queueing and full-library search — plus one AI feature scoped
tightly enough to stay consistent with it (on-device-only auto-chapters). Cross-device sync,
social features, AI summarization/chat-with-episode, and algorithmic recommendations remain
explicitly out of scope: all require a backend or cross-user data this app doesn't have.

**Smart Queues.** A small fixed set of computed filters — *Unplayed*, *Downloaded*, *Recently
Added* (last 7 days), *Shortest First* — each a `@Query`-driven ordering over subscribed-show
episodes. Not a custom rule builder (YAGNI for a single-user app); no new persisted rule model.
Surfaced as a row/section in Library above the show grid. Tapping one materializes it into the
existing `QueueItem` list as a one-time snapshot, so it inherits all existing queue behavior
(reorder, play-through, resume) with no new playback logic.

**Word-level transcript highlighting.** `TranscriptCue` gains `words: [WordTiming]?` (word text +
start/end in feed-seconds), populated only when `Transcript.source == "ondevice"` —
`SpeechAnalyzer` results carry real per-word timing. Published-transcript cues (WebVTT/SRT/PC2.0
JSON — almost always cue-level only) leave `words` nil; the transcript view highlights per-word
when timing exists and falls back to today's whole-cue highlight otherwise. No character-count
interpolation — an approximate highlight would misrepresent timing as real.

**On-device AI auto-chapters.** New `ChapterGenerator` service behind a protocol (same
testability pattern as `SpeechTranscriberEngine`), backed by Apple's on-device Foundation Models
framework — gated to Apple Intelligence-capable hardware/iOS, no network calls. Offered only when
an episode has zero published chapters (never overrides feed-provided ones) and a transcript
exists (generation runs on transcript text). On-demand via a "Generate chapters" affordance next
to the existing empty-chapters state — same UX pattern as "Transcribe episode," not automatic
background processing. `Chapter` gains `source: "feed" | "generated"`; `isAd` is always `false` for
generated chapters — this is topic segmentation, not ad detection, which stays out of scope.

**Full-library search (FTS5).** A SQLite FTS5 virtual table (external-content, same on-disk store
SwiftData already uses) indexes `TranscriptCue.text` and `Clip.text`/`Clip.note` together, kept in
sync with SwiftData writes via a thin sync step in `TranscriptService`/clip-save paths. Search
queries hit FTS5 directly via raw SQL (`MATCH`, `bm25()` ranking, `snippet()` for in-context
excerpts), then resolve hits back to `TranscriptCue`/`Clip` rows via SwiftData for navigation. This
becomes the backing for the already-spec'd Library search screen — one search box, ranked results
spanning transcripts *and* personal clips, replacing the earlier plain SwiftData-predicate
approach (`TranscriptSearch` as originally spec'd) for anything beyond small libraries.

**Data model additions:**
```
TranscriptCue.words: [WordTiming]?   — WordTiming: text, startTime, endTime (feed-seconds);
                                        nil unless source == "ondevice"
Chapter.source: "feed" | "generated" — generated chapters always have isAd == false
```

## Open Risks

- **Skip Silence via `MTAudioProcessingTap` + seek** is the highest-risk piece and is kept in v1
  scope by choice. `AVPlayer` buffering makes real-time detection + jump inherently coarse
  compared to commercial apps; if it feels too rough during implementation, the fallback is to
  keep the UI but soften behavior (larger silence threshold / gentler skips) rather than removing
  it. Voice Boost (same tap, gain only) is low-risk and unconditional.
- **Ad-skip only fires for feeds with real Podcasting 2.0 ad-marked chapters**, which are rare in
  practice — the feature may rarely activate; that's an accepted v1 tradeoff over faking it
- **iTunes Search API is unofficial/undocumented** with no SLA — acceptable for a personal v1, but
  a risk if usage grows; PodcastIndex remains the preferred fallback if signups reopen
- **Client-side RSS parsing (`RSSFeedParser`) must handle messy real-world feeds** (malformed
  dates, missing fields, nonstandard namespaces) that PodcastIndex would otherwise have normalized
  for us — expect to harden this incrementally against real shows during implementation
- **On-device transcription is iOS 26+ only and best-effort.** On iOS 17–25, episodes without a
  published transcript simply have none. Even on iOS 26+, transcribing a full episode is time/
  battery-intensive, so it's opt-in and limited to downloaded audio. Published Podcasting 2.0
  transcripts are the primary path and cover this gap wherever shows provide them; transcript
  coverage will otherwise be uneven.
- **On-device AI auto-chapters depend on Apple Intelligence hardware/OS gating**, which is a
  narrower device slice than `SpeechTranscriberEngine`'s iOS 26+ gate — expect this to be
  unavailable on a meaningful fraction of devices for a while; the "no chapters" empty state (v1)
  remains the fallback when generation isn't available or the user declines it.
- **FTS5 external-content sync must stay consistent with SwiftData writes** (cue/clip
  insert/update/delete) — a missed sync step silently degrades search rather than crashing, so this
  needs test coverage (fixture: write via SwiftData, assert FTS5 row count/content matches) rather
  than relying on manual verification.
- **Word-level highlighting only ever applies to on-device transcripts** — most episodes (published
  transcripts) keep today's whole-cue highlight; this is a real, visible inconsistency across
  episodes in the same library, not a bug, and should be treated as an accepted tradeoff rather
  than "fixed" later by interpolating fake word timing for published cues.
