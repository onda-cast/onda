# Known Bugs

## #1 — On-device transcribe crashes the app (OPEN, feature disabled)

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
