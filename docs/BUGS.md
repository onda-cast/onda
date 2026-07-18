# Known Bugs

## #1 — On-device transcribe crashes the app (FIXED 2026-07-16, button re-enabled)

**Root cause:** `TranscriptService` is `@MainActor`, so `requestSpeechAuthorization()` was
MainActor-isolated and the completion closure passed to `SFSpeechRecognizer.requestAuthorization`
inherited that isolation. TCC invokes the completion on a background queue
(`com.apple.root.default-qos`); the Swift runtime isolation check trapped
(`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue` → EXC_BREAKPOINT). Captured frame:
`closure #1 in closure #1 in static TranscriptService.requestSpeechAuthorization` ←
`TCC __TCCAccessRequest_block_invoke_8`.

**Fix:** made `requestSpeechAuthorization` `nonisolated` (and the completion `@Sendable`) so the
closure carries no actor isolation — resuming a continuation is thread-safe. Regression test:
`SpeechEngineReproTests.test_requestSpeechAuthorization_completionRunsOffMain_withoutCrashing`
(crashed with "signal trap" before the fix, passes after). Verified end-to-end in the simulator:
tap no longer kills the app. Note: on simulators without the downloadable speech model the flow
still ends back at the empty state (engine throws SFSpeechErrorDomain asset errors — pre-existing
environment limitation, see the XCTSkip in SpeechEngineReproTests).

Original investigation notes below, kept for history.

### Investigation log (historical)

**Symptom:** Tapping "Transcribe episode" (TranscriptView empty state) kills the app.
Reproduced 3× by user in iPhone 17 simulator, iOS 26.3. Button is currently `.disabled(true)`
in `TranscriptView.emptyState` — re-enable when fixed.

**Evidence so far (2026-07-16):**
- lldb attach caught it: `EXC_BREAKPOINT` in `libdispatch _dispatch_assert_queue_fail` on
  thread queue `com.apple.root.default-qos` — an actor/queue isolation assertion, not memory
  corruption. Batch-mode `bt all` truncated the crashing thread's stack (only frame 0);
  **next step: reattach with `-k 'thread backtrace -c 40'` (not `bt all`) to get our frame.**
- No .ips crash report is ever written (checked host + sim containers).
- The engine itself is exonerated for the pre-asset path: driving `SpeechTranscriberEngine`
  directly in a unit test (`SpeechEngineReproTests`, spoken.aiff fixture) does NOT crash — it
  throws cleanly (`SFSpeechErrorDomain` asset/format errors).
- Fix attempt 1 (didn't help): remote-command handlers `MainActor.assumeIsolated` →
  `Task { @MainActor }` hops in `NowPlayingCenter`. (Kept — correct regardless.)
- Fix attempt 2 (shipped with attempt 1, also didn't resolve): `AssetInventory`
  model download + supported-locale selection in `SpeechTranscriberEngine`.
  NOTE: the crash repro happened BEFORE these fixes were installed?? — verify: user's last
  repro was on build WITH both fixes installed (17:3x). Confirmed still crashing.

**Remaining suspects (untested):**
- `SFSpeechRecognizer.requestAuthorization` continuation path on iOS 26 (only step the unit
  test skips — test authorization in isolation).
- `AssetInventory.assetInstallationRequest`/`downloadAndInstall` internals asserting a queue
  (added in attempt 2 — the user's crash persisted with it, and the unit test path skipped
  via XCTSkip when assets unavailable, so this code is NOT exonerated by the test).
- Speech framework calling our `progress` closure / results-iteration Task on default-qos with
  an isolation-checked capture.

**How to resume:** relaunch app, attach `lldb -p <pid>` with
`--batch -o 'process continue' -k 'thread backtrace -c 40' -k quit`, reproduce, read OUR frame.
Or: extend `SpeechEngineReproTests` to also call `TranscriptService.requestSpeechAuthorization()`
first, matching the app flow exactly.

## #2 — SmartQueryParserTests NLTagger flake in simulators (MITIGATED 2026-07-17, XCTSkip guard)

**Symptom:** 6 of 9 `SmartQueryParserTests` fail intermittently on the same machine/simulator
(passed and failed on the same day at commit `5386e8a` with no code change): lemmas come back
as surface forms (`"books"`/`"mentioned"`), `.nameType` finds no `.personalName` for
"Tracy Alloway", and `.lexicalClass` tags everything `OtherWord` so function words like
"was"/"very" survive POS filtering.

**Root cause (environmental, not a regression):** the NaturalLanguage English models are
on-demand MobileAsset downloads; in a simulator they can be unloadable. Diagnostic probe run
while the flake was active showed: language ID fine (`en`), but lemma nil / POS `OtherWord` /
nameType `Other` **even with explicit `setLanguage(.english)`**, `[Query] Error for
queryMetaDataSync: 2` logged at first tagger use, and `NLTagger.requestAssets(for: .english,
tagScheme: .lemma)` never invoking its completion within 30s. So `setLanguage` hardening in
`SmartQueryParser` would not help — the models simply aren't there, and the parser already
degrades gracefully (surface-form terms, nil speaker) by design.

**Mitigation:** `skipUnlessNLAssetsAvailable()` in `SmartQueryParserTests` probes both schemes
the parser relies on (a lemma for "books", `.personalName` for "Tim Cook") and `XCTSkip`s the
5 NL-dependent tests when the models aren't loaded — same pattern as the speech-asset skips in
`SpeechEngineReproTests`. The regex/stopword tier tests still always run. If the skips show up
constantly (not just flakily), reboot the simulator or check network — the assets normally
recover on their own. Observed 2026-07-17: wedged at 09:57 (6 failures), fully recovered by
10:01 on the same booted simulator with zero code change — a `NLTagger.requestAssets` call in
a diagnostic run in between may have triggered the re-fetch.

## #3 — Hard crash on play, lock-screen artwork (FIXED 2026-07-18, commit `18e4e38`)

**Symptom:** app hard-crashes when playing audio. **DEVICE-ONLY** — every simulator play-path
probe passed, because the simulator never exercises MediaPlayer's lock-screen artwork rendering.
Reproduced from two `.ips` reports the user pulled off the device.

**Root cause (same family as #1):** the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, so the `MPMediaItemArtwork` request-handler closure `{ _ in image }` — formed in
`@MainActor` code in `NowPlayingCenter.prepareArtwork` — is inferred MainActor-isolated. But
MediaPlayer invokes that handler on its own background `accessQueue` (`jpegDataWithSize:`) to draw
the lock-screen/Control-Center art, tripping the Swift runtime executor check
(`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue` → EXC_BREAKPOINT / `swift_release`).
The first `.ips` showed the release-side of the same machinery; the decisive `.ips` had the
**triggered** thread on `*/accessQueue` with the top Onda frame inside `prepareArtwork`.

**Fix:** build the artwork in a `nonisolated static` helper that takes `Data` (Sendable) in and
returns the `MPMediaItemArtwork`, so the handler carries no actor isolation and is callable from
any queue. Also force-decode via `UIImage.byPreparingForDisplay()` so MediaPlayer's render never
triggers a lazy CGImage decode racing with the main actor. Verified on device.

**General rule (see also the onda-swift6-concurrency memory):** any closure handed to a non-SwiftUI
framework callback that can fire off-main (TCC, MediaPlayer, `MTAudioProcessingTap`, CoreAnimation)
must be formed in a `nonisolated` context / marked `@Sendable` — never let it inherit `@MainActor`.
Audited 2026-07-18: every other such callback already routes correctly (`queue: .main` +
`MainActor.assumeIsolated`, `DispatchQueue.main.async`, `Task { @MainActor }`, or `@Sendable`);
the artwork handler was the sole offender. Diagnose device-only crashes from the `.ips` by finding
the TRIGGERED thread's queue and its top Onda frame.

## #4 — UI tests: seeded "UITest Show" taps hijacked by restored mini-player (FIXED 2026-07-18)

**Symptom:** 6 OndaUITests failed consistently on a fresh iPhone 17 simulator — every test that
starts with `app.staticTexts["UITest Show"].firstMatch.tap()` (episode-list tests, the
show-settings gear test) reported seeded elements "not found". Failure-time accessibility
snapshots showed the app still on the Library grid with the **Now Playing sheet open**: the tap
had landed on the mini-player, not the grid tile.

**Root cause:** cross-test playback state, not seeding or identifiers. `PlaybackManager`
persists `lastPlayedEpisodeGuid` to UserDefaults, which survives app relaunches between UI
tests, and `UITestSeed`'s wipe-and-reseed recreates the episode with the same guid — so after
any earlier test tapped play (e.g. `AdvancedConfigUITests.test_player_skipButtons`, first in
alphabetical run order), every later launch ran `restoreLastEpisode()` and floated a mini-player
whose labels ("UITest Episode", "UITest Show") collide with the tests' `firstMatch` queries.
Tapping the mini-player's text opens the Now Playing sheet, under which the gear /
`play-episode` / `episode-search` elements don't exist. Whether a given test failed depended
purely on what ran before it, which is why single-test runs passed.

**Fix:** `UITestSeed.seed` now removes `PlaybackManager.lastEpisodeKey` (made internal) before
seeding, so every seeded launch starts with no restorable episode and the mini-player only
appears when a test itself starts playback. Full suite verified green (12/12) after the fix.

**Note:** "Test crashed with signal kill" failures seen alongside these are a separate,
nondeterministic launch-timeout flake on a loaded machine (app killed while "Setting up
automation session"); the affected tests differ per run and pass in isolation and on re-run.
