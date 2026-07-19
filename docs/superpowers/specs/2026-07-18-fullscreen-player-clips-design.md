# Fullscreen-player clips: start/end capture + Clip Review sheet

**Date:** 2026-07-18
**Status:** Approved design, ready for implementation plan

## Goal

Let a listener create a clip directly from the fullscreen player (`NowPlayingView`) by marking a
start and then an end while the episode plays, then review that clip in a dedicated sheet where they
can **listen to the range** and **adjust the start/end times** before saving.

Today clips can only be created from the lock-screen quick-clip ("last 45s") or from transcript
line selection, and the existing `ClipEditSheet` edits **only the note** — it cannot play the clip
or change its times. This feature adds in-player capture and a real time-editing + preview editor,
and makes that editor the single clip editor used everywhere.

## Existing infrastructure (unchanged unless noted)

- **`Clip`** model (`Onda/Models/Clip.swift`): `startTime`, `endTime` (feed seconds), `text`
  (transcript snapshot), `note`, `needsReview`, `createdAt`, `episode`. No schema change.
- **`ClipService`** (`Onda/Clips/ClipService.swift`): `makeClip`, `quickClip`, `updateNote`,
  `delete`, search/index. `quickClip` (lock screen) keeps its current cue-snapping behavior.
- **`ClipTextSnapshot.snap`** (`Onda/Clips/ClipTextSnapshot.swift`): expands a requested range
  **outward** to overlapped cue boundaries and joins their text.
- **`PlaybackManager.playClip`** + `clipEndBound` (`Onda/Playback/PlaybackManager.swift`): plays a
  bounded range and stops at the end. Position/duration/seeks are all in **feed seconds**.
- **`NowPlayingView`** (`Onda/Player/NowPlayingView.swift`): header icon row, chips, scrubber,
  transport, `captureToast` overlay, an ad banner, and a "Back to transcript" floating button.
  Also contains `parseTimecode(_:)` and a type-a-timecode alert used by the scrubber long-press.
- **Entry points that will now open the new editor:** Clips list tap
  (`Onda/Clips/ClipsView.swift`), transcript selection (`Onda/Player/TranscriptView.swift:134`),
  and lock-screen needs-review clips.

## Design decisions

| Decision | Choice |
| --- | --- |
| Marking model | **Look-back**: `Start` sets `start = position − 5s` (floored at 0); playback continues; `End` sets `end = current position`. |
| Look-back cushion | **5 s** constant. |
| Minimum clip length | **1 s** (`end ≥ start + 1`). |
| End-clip commit | Opens the review sheet with a **pending, unsaved** range. Cancel discards; Save commits. No orphan clip is created. |
| Editor scope | The new `ClipReviewSheet` **replaces** `ClipEditSheet` everywhere (player, Clips list, transcript, lock-screen review). |
| Time editing | Per-edge **nudge buttons** (±1s; long-press ±5s), a **"Set to playhead"** action, and a **tappable timecode** that opens type-a-timecode entry (reuse `parseTimecode`). |
| Preview | Plays `start→end` on a **loop**; opening the sheet pauses + snapshots the listener's position, closing restores it. |
| Stored times | The interactive editor stores the user's **exact** times (no outward cue snapping); text is re-derived from overlapping cues without moving the edges. |

## Components

### 1. In-player capture — `NowPlayingView`

- New `@State private var clipStart: TimeInterval?` (nil = not clipping).
- **Header**: add a scissors button (`headerIcon`). Inactive tapping calls `startClip()`; it shows
  an active/accent state while `clipStart != nil`.
- `startClip()`: `clipStart = max(0, playback.positionSeconds - Self.clipLookback)` where
  `clipLookback = 5`.
- **In-progress banner** (new small view, styled like the ad banner / `BackToTranscriptButton`):
  visible only while `clipStart != nil`. Shows a **live length** (`playback.positionSeconds −
  clipStart`, driven by the existing per-tick `positionSeconds` updates), an **End Clip** button,
  and a **×** cancel. Placed as an overlay so it doesn't reflow the scroll content.
- **End Clip**: captures `end = playback.positionSeconds`, clamps so `end ≥ start + minClipLength`,
  clears `clipStart`, and presents `ClipReviewSheet(episode:start:end:)`.
- **Cancel (×)**: `clipStart = nil`, nothing saved.

### 2. `ClipReviewSheet` (new; replaces `ClipEditSheet`)

Two initializers, mirroring today's sheet:

- `init(episode:start:end:)` — pending new clip.
- `init(clip:)` — edit existing clip (`needsReview` clips included).

Local editable state: `@State start`, `@State end`, `@State note`. Layout (brutalist, matches
existing sheet spacing):

1. **Excerpt** — `Text` of the live-derived transcript for `[start, end)`, or a "(no transcript for
   this range)" placeholder.
2. **Preview** — a play/stop button calling into `PlaybackManager` preview (see §3).
3. **Start** row — timecode label (tappable → type-a-timecode), `−`/`+` nudge buttons
   (±1s; long-press ±5s), and **"Set to playhead"**. Nudges clamp to `0 ≤ start ≤ end − minLen`.
4. **End** row — same, clamped to `start + minLen ≤ end ≤ episode.duration`.
5. **Note** — unchanged `TextField`.
6. **Cancel / Save** toolbar buttons.

Save:
- Pending-new → `ClipService.makeClipExact(episode:start:end:text:note:needsReview:false)`.
- Edit-existing → update `clip.startTime/endTime/text/note`, set `needsReview = false`, re-index.

On appear it calls `playback.beginClipPreview()`; Preview calls
`playback.previewRange(episode:start:end:)` with the sheet's episode; on dismiss (Save or Cancel) it
calls `playback.endClipPreview()` to restore the listener's episode + position.

### 3. `PlaybackManager` — scoped looping preview (episode-aware)

Preview must work even when the clip being edited belongs to an episode other than the one the
listener is on (editing an old clip from the Clips list). So the snapshot captures the episode too,
and preview loads the clip's episode if needed and restores the listener's episode on close.

New state:
- `private var clipPreviewRange: (start: TimeInterval, end: TimeInterval)?`
- `private var preClipPreview: (episode: Episode?, position: TimeInterval, wasPlaying: Bool)?`

New API:
- `beginClipPreview()` — snapshot `(currentEpisode, positionSeconds, isPlaying)` into
  `preClipPreview`, pause.
- `previewRange(episode:start:end:)` — if `episode !== currentEpisode`, `play(episode,
  autoDownload: false)` to load it; then seek to `start`, set `clipPreviewRange`, play.
- `stopPreviewPlayback()` — clear `clipPreviewRange`, pause (leaves position where it is; used by
  the sheet's stop button).
- `endClipPreview()` — clear `clipPreviewRange`. If the snapshot's episode differs from
  `currentEpisode`, reload the snapshot episode at its saved position; otherwise seek back to the
  saved position. Resume iff `wasPlaying`. Clear the snapshot.

The pending-new / player / lock-screen cases have `clip.episode === currentEpisode`, so the
cross-episode reload only runs when editing an old clip while a different episode plays.

Time-update tick (`handleTimeUpdate`): when `clipPreviewRange` is set and `t ≥ range.end`, **seek
back to `range.start`** (loop) instead of stopping. This branch precedes the existing
`clipEndBound` / ad / outro logic and returns early. Any normal `seek`/`skip` clears
`clipPreviewRange` (as they already clear `clipEndBound`) so preview never "sticks".

### 4. Text derivation — `ClipTextSnapshot`

Add a non-expanding helper alongside `snap`:

```swift
/// Joins the text of cues overlapping [start, end) WITHOUT moving the boundaries.
static func text(cues: [CueSpan], start: TimeInterval, end: TimeInterval) -> String
```

`ClipReviewSheet` uses this to show the live excerpt and to compute the saved `text`. `snap` and
`quickClip` are untouched (lock-screen quick clips still snap outward).

### 5. `ClipService`

Add an exact-times creator (no outward snapping):

```swift
@discardableResult
func makeClipExact(episode:start:end:text:note:needsReview:) -> Clip
```

`ClipEditSheet` is deleted; `ClipsView` and `TranscriptView` are updated to present
`ClipReviewSheet`.

## Data flow

```
Start (scissors)  ──▶ clipStart = pos − 5s ; banner shows live length
End Clip          ──▶ end = pos (clamped) ; present ClipReviewSheet(episode,start,end)
Sheet appears     ──▶ beginClipPreview() (pause + snapshot listener episode/position/play)
Preview           ──▶ previewRange(episode,start,end) → loads episode if needed → loops start↔end
Nudge / type / set──▶ start/end update ; excerpt re-derived ; preview range follows on next Preview
Save              ──▶ makeClipExact(...) ; endClipPreview() (restore episode/position/play)
Cancel            ──▶ endClipPreview() ; nothing saved
```

## Error / edge handling

- No transcript: excerpt shows placeholder; clip still saves with empty `text`.
- Clamp keeps `0 ≤ start`, `end ≤ episode.duration`, `end ≥ start + 1s` under every nudge/typed
  value; malformed typed timecodes (per `parseTimecode`) are ignored.
- Backgrounding / episode change while a clip is in progress: `clipStart` is view state, so leaving
  the player discards an un-ended in-progress clip (acceptable; matches "pending, unsaved").
- Preview loads its episode with `autoDownload: false`; a not-downloaded episode streams like normal
  playback without triggering a background save.

## Testing

- **`ClipTextSnapshot.text`**: overlapping cues joined; no overlap → empty; edge-touching
  (`cue.end == start`, `cue.start == end`) excluded; boundaries never moved.
- **`PlaybackManager` preview**: `previewRange` loops (tick at `≥ end` seeks to `start`, keeps
  playing); `beginClipPreview` pauses + snapshots; `endClipPreview` restores position and resumes
  only if `wasPlaying`; a `seek`/`skipForward` during preview clears `clipPreviewRange`.
- **Clamp / timecode math**: nudges respect min length and duration bounds; `start` can't cross
  `end`; `parseTimecode` round-trips typed edits.
- **`ClipService.makeClipExact`**: stores exact times (no expansion), sets `needsReview=false`,
  indexes body text.

## Out of scope (YAGNI)

- Starting a *new* clip (the scissors/banner flow) for anything other than the currently-playing
  episode. (Editing an existing clip whose episode isn't current is supported — preview loads it.)
- Waveform visualization / dual-handle range slider (nudge + typed timecodes only).
- Configurable look-back cushion or per-show clip defaults.
- Changing lock-screen quick-clip or transcript-selection capture behavior beyond swapping the
  editor sheet.
