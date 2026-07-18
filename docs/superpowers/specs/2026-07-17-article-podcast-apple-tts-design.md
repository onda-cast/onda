# Article-to-Podcast (Apple TTS) — Design

**Status:** Approved for planning
**Date:** 2026-07-17

## Summary

Let the user turn a web article into a playable "episode" inside Onda, narrated with
Apple's on-device text-to-speech (`AVSpeechSynthesizer`). Two entry points: pasting a
URL in-app, and sharing a link into Onda from Safari/Mail/etc. via a Share Extension.
Converted articles live in a single synthetic "Articles" show and reuse Onda's existing
playback, download, and transcript infrastructure unchanged.

Everything runs on-device — article fetch is a plain HTTP GET, readability extraction
runs in a local `WKWebView`, and speech synthesis is `AVSpeechSynthesizer`. No backend,
consistent with the rest of Onda.

## Goals

- Paste an article URL in-app → get back a playable, downloaded, transcript-synced
  episode in an "Articles" show.
- Share a link from another app into Onda and have the same thing happen, even if Onda
  wasn't running when the share happened.
- Pick which system voice narrates articles.
- Reuse existing playback/download/transcript UI — no new player screens.

## Non-goals

- Per-source shows (grouping articles by originating site) — out of scope, single
  "Articles" show only.
- Word-level transcript highlighting for articles — sentence-level only (see
  "TTS rendering" below for why).
- ~~Surviving app termination mid-conversion~~ — **reversed 2026-07-18**: conversions now
  survive suspension and termination via a persistent queue + background processing. See
  "Addendum: Background conversion pipeline" at the end of this document.
- Editing/curating extracted article text before synthesis.

## Data model changes

All changes are additive; no existing fields change type or meaning.

**`Podcast`** — add `isLocal: Bool = false`. A single synthetic "Articles" podcast is
created lazily (on first successful article conversion) with:
- `feedURL = URL(string: "onda-local:articles")!` (stable sentinel; satisfies the
  `.unique` constraint without a real feed)
- `isLocal = true`, `isSubscribed = true`, `title = "Articles"`, `artworkURL = nil`
  (a bundled static icon is used in place of artwork wherever `isLocal` is true)

UI treats `isLocal` shows specially: no "Check for Updates" action (there's no feed to
poll), "Unsubscribe" is relabeled "Delete Articles Show" (destructive, removes all
converted articles). This is a real, permanent row deletion (not the usual archive/
unsubscribe soft-delete), so it ignores the keep-transcripts setting entirely — every
transcript goes with its episode regardless of that preference.

**`Episode`** — add `sourceType: String = "feed"`, set to `"article"` for converted
episodes. Mirrors the existing `Chapter.source` (`"feed" | "generated"`) tagging
convention. No other field changes:
- `audioURL` — the rendered `file://` URL of the local `.m4a` (there is no remote
  source at all for these episodes)
- `duration` — measured from the rendered audio file
- `publishDate` — date the conversion completed (article publish dates are unreliable
  to parse across arbitrary sites, so "date added" is used instead)
- `notes` — extracted byline / site name, if Readability found one

**New model `ArticleSource`** (1:1 with `Episode`, cascade delete, same shape as
`DownloadedFile`/`Transcript`):

```swift
@Model
final class ArticleSource {
    var sourceURL: URL
    var siteName: String?
    var addedAt: Date
    var episode: Episode?
}
```

**`Transcript.source`** gains a third value, `"tts"`, for article transcripts. Cues have
`words: nil` (same shape as the existing `"published"` source) since timing is captured
at sentence granularity, not word granularity.

**`ShowSettings`** — add `ttsVoiceIdentifier: String?` (`nil` = system default
`AVSpeechSynthesisVoice`). Only meaningful on the Articles show's settings row; every
other podcast's row just carries `nil` and ignores it.

No changes needed to `PlaybackManager`, `DownloadManager`, or download-state UI — an
article episode gets a real `DownloadedFile` row the moment rendering finishes, so it
looks exactly like a normally-downloaded episode to everything downstream of that point.

## Extraction + TTS rendering pipeline

New `Onda/Article/` directory (mirrors the isolation of `Onda/Transcription/`).

### `ArticleExtractor`

Fetches the URL's HTML via `URLSession`, loads it into an off-screen `WKWebView`,
injects a bundled copy of Mozilla's `Readability.js` (same algorithm behind Safari
Reader / Firefox Reader View), and evaluates it to get back
`{ title, byline, siteName, textContent }`. Runs on the main actor (`WKWebView`
requirement).

Throws a typed `ArticleExtractionError`: `.invalidURL`, `.fetchFailed`,
`.noReadableContent`, `.timeout`. No automatic retries — surfaced to the user with a
plain error message and a manual Retry action.

### `SentenceSplitter`

Pure function. Splits `textContent` into sentences using `NLTokenizer(unit: .sentence)`
(Natural Language framework — already available, no new dependency). More reliable
across locales/punctuation styles than a regex-based splitter.

### `ArticleSpeechRenderer`

For each sentence:
1. Build an `AVSpeechUtterance` (voice = `ShowSettings.ttsVoiceIdentifier` resolved
   against `AVSpeechSynthesisVoice`, or system default if `nil`).
2. Call `synthesizer.write(_:toBufferCallback:)`.
3. Append the returned PCM buffers to one growing `AVAudioFile`, opened once (on the
   first buffer) with AAC/`.m4a` output settings matching that buffer's processing
   format.
4. Track cumulative written duration; emit a `TranscriptCue(startTime:, endTime:, text:)`
   spanning the sentence's boundaries in the output file.

Returns the finished file URL, total duration, and the ordered list of cues.

A failure on any single sentence aborts the whole render — no partial/gappy audio
files. This is why per-sentence-utterance rendering was chosen over one long utterance
with `willSpeakRangeOfSpeechString` word-level callbacks: the latter would give
word-level transcript highlighting, but ties correctness to delegate-callback timing
during offline buffer rendering (less battle-tested than during real playback) and an
error partway through a long article loses everything synthesized so far. Sentence
granularity is simpler, recoverable per-retry, and still gives real tap-to-seek
transcript sync — just not word-by-word highlighting.

### `ArticleConversionService`

`@MainActor @Observable`, same shape as `TranscriptService`. Orchestrates
extractor → splitter → renderer for a queue of pending URLs (fed by both the in-app Add
Article flow and the share-extension handoff queue below).

- Tracks ephemeral per-request state (`progress: [URL: Stage]`,
  `lastFailure: [URL: Error]`) — **not persisted**. If the app is killed mid-conversion,
  the in-flight item is simply gone; the user re-adds the link (or, for a
  share-extension-originated URL, re-shares it).
- Only on full pipeline success does it insert `Episode` + `ArticleSource` +
  `DownloadedFile` + `Transcript`/`TranscriptCue` rows into SwiftData, in one batch —
  a half-finished conversion never appears as a broken `Episode` row.
- Lazily creates the "Articles" `Podcast` + its `ShowSettings` on first success, same
  pattern as `ShowSettings` being created lazily today on first subscribe/settings-open.

## Storage

Rendered `.m4a` files are written directly into the existing
`Application Support/Downloads/` directory (the same directory
`DownloadManager.fileURL(named:)` uses), named after the episode's `guid` with a `.m4a`
extension — parallel to, but independent of, `DownloadManager.fileName(for:)`'s
`.mp3`-only convention (that method is untouched; a separate small helper in the
Article pipeline picks the `.m4a` name and path). A `DownloadedFile` row is recorded via
the existing `PersistenceActor.recordDownload(...)` the moment the file is complete, so
retention/eviction, storage accounting, and offline playback all work unmodified. One
exception: `EpisodeRetentionService`'s destructive eviction sweeps (listened-age and
download-cap) explicitly skip `sourceType == "article"` episodes — their audio is the
local `.m4a` itself with no remote feed to re-download from, so evicting it would be
silent, permanent data loss rather than a reclaimable cache eviction.

## In-app UI

- **Add Article**: new toolbar button on `LibraryView` (next to Clips/Search) opens a
  sheet with a URL text field + "Add" button. On submit: validate `http(s)`, dismiss the
  sheet immediately, enqueue into `ArticleConversionService` — no blocking spinner.
- **In-flight progress**: while converting, a synthetic row appears at the top of the
  Articles show's episode list (sourced from `ArticleConversionService`'s in-memory
  state, not a real `Episode`) showing the URL/domain and current stage (fetching →
  extracting → synthesizing). On failure: inline error + Retry/Dismiss. On success:
  replaced by the real `Episode` row once the SwiftData insert lands. Until the Articles
  show exists (i.e. before the first conversion has ever succeeded), these pending/error
  rows are shown instead at the top of the Library, above the shows list.
- **Articles show**: appears in the Library like any subscribed show. Episode list,
  playback, transcript view, and download management all reuse existing screens
  unchanged.
- **Voice picker**: `ShowSettingsSheet`, when opened on the Articles show
  (`podcast.isLocal`), gets an additional "Voice" row listing
  `AVSpeechSynthesisVoice.speechVoices()` (filtered to the current locale's language by
  default, with an option to show all languages), writing to
  `ShowSettings.ttsVoiceIdentifier`. The same sheet hides "Check for Updates" and
  relabels "Unsubscribe" → "Delete Articles Show" when `isLocal`.

## Share Extension

- New Xcode target `OndaShareExtension` (Share Extension template, activation rule:
  URLs and web pages), added to `project.yml`. Requires an App Group entitlement
  (`group.com.onda.shared`) on both the main app and the extension.
- The extension does **no heavy work** — no `WKWebView`, no TTS (extensions have tight
  memory/time limits; that work belongs in the host app). It reads the shared
  `NSItemProvider` URL, appends it to a small JSON array
  (`pending-articles.json`) in the App Group's shared container, and dismisses itself.
- On foreground (`OndaApp`'s existing scene-phase handling — the same place
  `FeedRefreshService` hooks in), the main app reads and clears
  `pending-articles.json` and enqueues each URL into `ArticleConversionService`, the
  same path as the in-app Add Article flow.
- `pending-articles.json` is the one piece of state in this feature persisted outside
  SwiftData, by necessity: the extension and app are different processes, and the app
  may not be running when a share happens.

## Error handling

Every failure mode surfaces as a dismissible/retryable state; nothing fails silently.

| Failure | Where it surfaces | Recovery |
|---|---|---|
| Invalid / unreachable URL | Add Article sheet, before pipeline starts | Fix and resubmit |
| No readable content (JS-heavy page, paywall) | In-flight row error | Retry re-runs extraction only |
| TTS render failure mid-article | In-flight row error | Retry restarts from extraction (article text isn't cached) |
| Share-extension URL fails conversion | Same in-flight-row error UI as in-app-added URLs | Stays visible until resolved; not silently dropped from the queue |

## Testing

- `SentenceSplitter`, `ArticleSource`/model plumbing: plain unit tests.
- `ArticleExtractor`: unit tests against fixture HTML (a few saved real-world article
  pages) run through the bundled Readability.js in a real `WKWebView` — same approach
  `RSSFeedParser` uses against fixture feeds.
- `ArticleSpeechRenderer`: unit test that a short fixed sentence list produces a valid
  audio file with monotonically increasing, non-overlapping cue boundaries and a total
  duration matching the file. No assertion on exact durations (voice-dependent) — just
  structural correctness.
- `ArticleConversionService`: unit tests with fake extractor/renderer closures (same DI
  pattern as `TranscriptService`), covering success, partial failure, and retry.
- Share extension → app handoff: tested at the `pending-articles.json` read/write level,
  not a full extension UI test.
- Manual/UI: add an article in the simulator, verify playback, transcript tap-to-seek,
  and the voice picker end-to-end. The share sheet itself needs a device or a second
  simulator app to exercise for real.

## Addendum: Background conversion pipeline (2026-07-18)

Reverses the original "conversions don't survive termination" non-goal.

**Persistent queue as source of truth.** The App Group file `pending-articles.json`
(`PendingArticlesQueue`) stops being a drain-once handoff and becomes the durable record
of every not-yet-converted URL. Entry format changes from `[URL]` to
`[{url, attempts}]` (legacy plain-URL arrays still decode, mapping to `attempts: 0`;
the JSON object format is extensible — e.g. a future `extractedText` field for
extract-at-add-time — without another migration). The share extension keeps appending
exactly as before.

Queue lifecycle: `add(url:)` appends; a successful conversion or a user DISMISS removes;
each failure increments `attempts`. On every foreground activation the service
*reconciles* instead of draining: entries with `attempts < 3` restart conversion
automatically (idempotent against in-flight work); entries at the cap surface as failed
rows with manual RETRY only. Restart-from-scratch is safe because episodes are inserted
only on full success and partial audio files are cleaned up on failure.

**Background execution, two layers:**
1. *Continuation:* each conversion wraps itself in `UIApplication.beginBackgroundTask`,
   so leaving the app grants ~30s of continued execution — enough for typical articles.
2. *`BGProcessingTask`* (identifier `com.onda.articles.convert`, added to
   `BGTaskSchedulerPermittedIdentifiers` beside `com.onda.refresh`): scheduled on
   scene-background whenever the queue holds sub-cap entries, with
   `requiresNetworkConnectivity = true`. The handler processes queue entries
   sequentially (skipping URLs that already have an in-flight attempt — a suspended
   foreground conversion resumes alongside the background wake); its expiration handler
   cancels the current conversion, whose queue entry survives for the next window.

**Known risk:** Readability extraction runs in a `WKWebView`. During active
`BGProcessingTask` runtime the process is running, so web content should execute, but
this is the least-documented corner of the design; the extensible queue-entry format
exists precisely so extraction can move to add-time if this proves unreliable.

**Failure observability:** conversion failures are logged via `os.Logger`
(subsystem `com.chasegilliam.Onda`, category `articles`) in addition to the UI row —
previously a failure existed only as ephemeral UI state.
