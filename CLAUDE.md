# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Onda is an iOS podcast-listening app (SwiftUI, iOS 17+, SwiftData). Single-user, no backend of
our own — podcast discovery comes from Apple's iTunes Search API, episode/chapter metadata and
audio come directly from each show's RSS feed (parsed client-side). Full design/scope doc:
`docs/superpowers/specs/2026-07-16-onda-ios-podcast-app-design.md`. Known-bug history/investigation
notes: `docs/BUGS.md`.

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `Onda.xcodeproj` is
generated from `project.yml` and is not hand-edited. After changing `project.yml` (or adding/
removing files, which XcodeGen picks up via folder references), regenerate the project:

```sh
xcodegen generate
```

## Commands

Build:

```sh
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```

Run all tests (unit + UI):

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```

Run a single test class or method:

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PlaybackManagerTests
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OndaTests/PlaybackManagerTests/testSomeBehavior
```

Lint (uses [SwiftLint](https://github.com/realm/swiftlint); config in `.swiftlint.yml`; also runs
automatically as an Xcode build phase — a warning is printed instead of failing the build if
SwiftLint isn't installed):

```sh
swiftlint lint          # report violations
swiftlint --fix         # autocorrect what can be autocorrected, then re-run lint to check the rest
```

## Architecture

Plain SwiftUI "MV" pattern: `@Observable` model/service classes, no separate ViewModel layer.
Views read directly from SwiftData `@Query` and from `@Observable` service singletons injected
into the environment (see `Onda/OndaApp.swift`, which constructs every service and injects it via
`.environment(...)`).

**Data model (SwiftData).** Schema is declared in `Onda/Models/ModelSchema.swift`. Key models:
`Podcast`, `Episode` (belongs to `Podcast`), `Chapter` (belongs to `Episode`, `isAd` derived from
a Podcasting 2.0 `<podcast:chapters>` link), `ShowSettings` (1:1 with `Podcast`, created lazily on
first subscribe/settings-open), `QueueItem` (cross-show manual queue), `DownloadedFile` (1:1 with
`Episode`), `Transcript`/`TranscriptCue` (1:1 with `Episode`; source is `"published"` from a feed's
`<podcast:transcript>` tag or `"ondevice"` from on-device transcription).

**Canonical timeline.** `Episode.playbackPosition`, `Chapter.startTime`, `TranscriptCue` times, the
scrubber, and all seeks are always expressed in **original feed seconds**, persisted every ~5s
during playback. Intro/outro trim and skip-silence are playback-layer effects only — they change
what wall-clock time maps to a given feed second, but never the stored/displayed timeline. Keep
new playback-affecting code in feed-seconds and do the wall-clock conversion at the playback layer,
not in models or view state.

**Directory layout mirrors feature areas**, not MVC layers: `Playback/` (engine, boost, silence
skip, ad windows, now-playing center), `Player/` (Now Playing / transcript / queue views),
`Transcription/` (parsing + on-device speech engine, iOS 26+ only — see the `@available(iOS 26, *)`
gate in `OndaApp.swift`), `Downloads/` (download manager + `PersistenceActor` for background file
I/O), `Networking/` (iTunes Search client, RSS parsing), `Services/` (feed refresh, subscriptions),
`Search/` (natural-language query parsing for transcript search), `Models/`, `Theme/` (neo-brutalist
style system — thick borders, hard shadows, sharp corners), `Shell/` (tab root views).

**Background work**: `FeedRefreshService` registers a `BGTaskScheduler` background refresh task
(`com.onda.refresh`, declared in `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`) and is
triggered on scene-phase transitions in `OndaApp.swift`.
