---
name: verify
description: Build, launch, and drive Onda in the iOS Simulator to verify a change end-to-end.
---

# Verifying Onda in the Simulator

## Build + install + launch (dedicated device — the shared "iPhone 17" sim is contended by sibling worktree agents)

```sh
RUNTIME=$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS[^ )]*' | tail -1)
UDID=$(xcrun simctl create onda-verify com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RUNTIME")
xcrun simctl boot "$UDID"
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination "id=$UDID" -derivedDataPath /tmp/onda-verify-dd
xcrun simctl install "$UDID" /tmp/onda-verify-dd/Build/Products/Debug-iphonesimulator/Onda.app
open -a Simulator --args -CurrentDeviceUDID "$UDID"   # only honored if Simulator wasn't already running
xcrun simctl launch "$UDID" com.chasegilliam.Onda
# when done: xcrun simctl shutdown "$UDID" && xcrun simctl delete "$UDID"
```

## Gotchas (each cost real time)

- **Wrong window**: if Simulator.app was already running, the `--args` flag is ignored and you may be looking at the shared "iPhone 17" device with a STALE Onda install. Check the window title = your device name (Window menu lists all windows). A missing feature that IS in the binary usually means wrong window.
- **Do NOT quit Simulator.app to fix window focus** — quitting shuts down every booted device, including the shared one sibling agents use. Use Window menu instead.
- **Debug binaries**: the app's real code lives in `Onda.app/Onda.debug.dylib`, not the `Onda` stub executable — `strings` the dylib when checking whether a symbol/feature made it into a build.
- **Typing into the sim is flaky** (held-key accent popover swallows text). Paste instead: `printf 'text' | xcrun simctl pbcopy UDID`, then click the field and `cmd+v`.
- **Local test pages**: serve from the scratchpad with `python3 -m http.server PORT`; the sim reaches the host at `http://localhost:PORT/...` (ATS exempts loopback). An unreachable port (e.g. `http://localhost:9/x`) is a reliable failure-path trigger.
- Menu-bar clicks land wrong while a menu is animating — Escape, wait 1s, then click.

## Flows worth driving for the article-to-podcast feature

Library toolbar → Add Article (link icon) → paste URL → ADD ARTICLE (sheet dismisses immediately; no progress visible in Library until the Articles show exists). Articles show: pending/error rows at top of the episode list; header shows "Delete Show" for the local show; gear → "Article Voice" section (local show only). Player: transcript via the quote icon; tapping a cue's ▶ seeks and returns to the player with a "Back to transcript" pill.
