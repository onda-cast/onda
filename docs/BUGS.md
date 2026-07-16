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
