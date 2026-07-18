# Advanced Configuration (Overcast-inspired) — Design

**Date:** 2026-07-18
**Status:** Implemented
**Scope:** Sub-project 1 of 3 (global playback defaults + Nitpicky Details + download policy).
Sub-project 2 (smart playlists + priorities) gets its own spec later.

## Background

Overcast's configuration surface splits into global playback defaults with per-show
"custom" overrides, a "Nitpicky Details" tier of small power-user behaviors, download/storage
policy, and smart playlists. Onda already has a rich *per-show-only* settings model
(`ShowSettings`: speed, voice boost, skip silence, ad skip, auto-download, intro/outro trim,
retention overrides) but no global defaults layer, hardcoded seek intervals, and no download
policy controls. This spec closes those gaps.

## 1. Settings architecture: global defaults + per-show overrides

### Global playback defaults (new, in `AppSettings`)

UserDefaults-backed, alongside the existing retention defaults:

| Key | Type | Default |
|---|---|---|
| `defaultSpeed` | Double | 1.0 |
| `defaultVoiceBoost` | Int (0/1/2) | 0 |
| `defaultSkipSilence` | Bool | false |
| `defaultAdSkipMode` | String (off/manual/auto) | "off" |
| `defaultAutoDownload` | Bool | false |

### `ShowSettings` becomes optional-override

`speed`, `voiceBoost`, `skipSilence`, `adSkipMode`, `autoDownload` change from concrete
values to optionals; **nil = inherit the global default**, mirroring the existing
retention-override fields (`maxDownloadsKeptOverride` etc.).

### Resolver

One resolution point — e.g. `ResolvedPlaybackSettings` built from
`(ShowSettings?, AppSettings)` — becomes the only thing `PlaybackManager`,
`FeedRefreshService` (auto-download), and the UI captions read. No call site reads
`settings?.speed` directly anymore.

### Migration

One-time pass at launch (guarded by a UserDefaults flag): for every `ShowSettings`,
any field equal to the old hardcoded default (speed 1.0, boost 0, skipSilence false,
adSkipMode "off", autoDownload false) becomes nil (inherit); any other value stays as an
explicit override. User customizations are preserved exactly; untouched shows begin
tracking the global default.

### UI

- **Profile → new "Playback" section**: the four global playback controls plus Nitpicky
  items (below), using the existing SegmentedRow/stepper idioms.
- **`ShowSettingsSheet`**: playback + auto-download rows adopt the Default/Custom
  three-way pattern already used by the retention rows, with "Default: 1.5×"-style
  captions resolving the current global value.

## 2. Nitpicky Details (all global, in `AppSettings`)

- **Seek intervals** — `seekForwardSec` (default 30), `seekBackSec` (default 15);
  choices 10/15/30/45/60. Applied to Now Playing buttons, `MPRemoteCommandCenter`
  skip-interval registration (updated live when changed), and any mini-player skips.
- **Smart Resume** — bool, default on. On resume after a pause > ~1 minute, rewind by an
  amount scaled to pause length (≈5 s after minutes, up to ≈30 s after hours; fixed
  internal thresholds, not user-tunable). Optional phase 2 under the same toggle: snap
  the resume point to the nearest detected silence within a small window, reusing
  `SilenceDetector` RMS logic against the downloaded file. If silence-snap proves
  unreliable, ship rewind-only; the toggle's meaning is unchanged.
- **Autoplay next** — bool, default on (current behavior). Off: playback stops at
  episode end (outro-trim end counts as end); the queue is left untouched.
- **Seek acceleration** — bool, default on. Consecutive skip taps within ~2 s multiply
  the interval (1×, 2×, 4× cap), resetting when the window lapses. Ephemeral
  player-layer state; nothing persisted.

## 3. Download & storage policy

- **Wi-Fi-only downloads** — global bool, default on. Sets `allowsCellularAccess` on
  `DownloadManager`'s `URLSession` configuration. Both auto-downloads and manual taps
  respect the toggle; no per-download cellular prompt in v1.
- **Delete-played timing** — reframe the existing retention UI as presets over
  `autoDeleteListenedAfterDays`: **When completed** (0) / **After 1 day** (1) /
  **After N days** (custom stepper) / **Never** (-1). Engine unchanged; this is a UI
  reframing plus preset mapping. Per-show override continues to work via
  `autoDeleteListenedAfterDaysOverride`.
- **Global auto-download default** — covered in §1 (`defaultAutoDownload` +
  optional per-show override).

## 4. Out of scope (future work)

- Smart playlists, per-show priorities, "Play Top Episodes Next" — sub-project 2, own spec.
- One-tap play (Onda's row-tap interaction model differs).
- Remote-click remapping (iOS API limits; partial equivalents only).
- OPML import/export; notifications (`notifMode` remains a dead field — candidate for
  cleanup or future wiring); streaming controls; icon badge.

## 5. Testing

- Unit: resolver (override vs inherit per field), migration (default→nil, custom→kept,
  idempotent via flag), Smart Resume rewind scaling thresholds, seek-acceleration
  windowing/reset, delete-played preset ↔ days mapping.
- Manual: seek intervals on lock screen remote commands, Smart Resume feel, autoplay-off
  end-of-episode behavior, Wi-Fi-only enforcement — via simulator (`verify` skill).
