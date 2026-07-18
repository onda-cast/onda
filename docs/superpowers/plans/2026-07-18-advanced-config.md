# Advanced Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Global playback defaults with per-show overrides, Overcast-style "nitpicky" playback options (seek intervals, Smart Resume, autoplay toggle, seek acceleration), and download policy (Wi-Fi-only, delete-played presets), per `docs/superpowers/specs/2026-07-18-advanced-config-design.md`.

**Architecture:** New global defaults live in `AppSettings` (UserDefaults). `ShowSettings` playback fields become optionals (nil = inherit), resolved through a single `ResolvedPlaybackSettings` struct that `PlaybackManager`, `FeedRefreshService`, and the UI all read. A one-time launch migration normalizes existing default-valued rows to nil.

**Tech Stack:** SwiftUI, SwiftData, XCTest. XcodeGen picks up new files automatically — run `xcodegen generate` after adding any file.

## Global Constraints

- iOS 17+, SwiftUI "MV" pattern, `@Observable` services injected via `.environment(...)` in `OndaApp.swift`.
- All timeline math stays in feed-seconds (see CLAUDE.md).
- Use `.scaledFont(size, weight:)`, `theme.color(_:)`, existing `SegmentedRow`/`BrutalCard` idioms in UI.
- Build: `xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
- Tests: same command with `test` and `-only-testing:OndaTests/<Class>`.
- SwiftLint must stay clean (`swiftlint lint`).
- Commit after every task.

---

### Task 1: Global defaults in `AppSettings`

**Files:**
- Modify: `Onda/Theme/AppSettings.swift`
- Test: `OndaTests/AppSettingsTests.swift` (create)

**Interfaces:**
- Produces (all on `AppSettings`, UserDefaults-persisted, with these defaults):
  `defaultSpeed: Double = 1.0`, `defaultVoiceBoost: Int = 0`, `defaultSkipSilence: Bool = false`, `defaultAdSkipMode: String = "off"`, `defaultAutoDownload: Bool = false`, `seekForwardSec: Int = 30`, `seekBackSec: Int = 15`, `smartResumeEnabled: Bool = true`, `autoplayNext: Bool = true`, `seekAccelerationEnabled: Bool = true`, `wifiOnlyDownloads: Bool = true`.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/AppSettingsTests.swift`:

```swift
//  AppSettingsTests.swift
import XCTest
@testable import Onda

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_playbackDefaults_haveExpectedInitialValues() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(s.defaultSpeed, 1.0)
        XCTAssertEqual(s.defaultVoiceBoost, 0)
        XCTAssertFalse(s.defaultSkipSilence)
        XCTAssertEqual(s.defaultAdSkipMode, "off")
        XCTAssertFalse(s.defaultAutoDownload)
        XCTAssertEqual(s.seekForwardSec, 30)
        XCTAssertEqual(s.seekBackSec, 15)
        XCTAssertTrue(s.smartResumeEnabled)
        XCTAssertTrue(s.autoplayNext)
        XCTAssertTrue(s.seekAccelerationEnabled)
        XCTAssertTrue(s.wifiOnlyDownloads)
    }

    func test_playbackDefaults_persistAcrossInstances() {
        let d = makeDefaults()
        let s = AppSettings(defaults: d)
        s.defaultSpeed = 1.5
        s.defaultVoiceBoost = 2
        s.seekForwardSec = 45
        s.autoplayNext = false
        s.wifiOnlyDownloads = false
        let reloaded = AppSettings(defaults: d)
        XCTAssertEqual(reloaded.defaultSpeed, 1.5)
        XCTAssertEqual(reloaded.defaultVoiceBoost, 2)
        XCTAssertEqual(reloaded.seekForwardSec, 45)
        XCTAssertFalse(reloaded.autoplayNext)
        XCTAssertFalse(reloaded.wifiOnlyDownloads)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/AppSettingsTests` (after `xcodegen generate`)
Expected: BUILD FAILS — `defaultSpeed` etc. not defined.

- [ ] **Step 3: Implement**

In `AppSettings.swift`, add after the existing key constants:

```swift
    private static let defaultSpeedKey = "defaultSpeed"
    private static let defaultBoostKey = "defaultVoiceBoost"
    private static let defaultSkipSilenceKey = "defaultSkipSilence"
    private static let defaultAdSkipKey = "defaultAdSkipMode"
    private static let defaultAutoDownloadKey = "defaultAutoDownload"
    private static let seekForwardKey = "seekForwardSec"
    private static let seekBackKey = "seekBackSec"
    private static let smartResumeKey = "smartResumeEnabled"
    private static let autoplayNextKey = "autoplayNext"
    private static let seekAccelKey = "seekAccelerationEnabled"
    private static let wifiOnlyKey = "wifiOnlyDownloads"
```

Add stored properties (same `didSet`-persist pattern as the existing ones):

```swift
    // MARK: Global playback defaults — a show inherits these unless it has an override.
    var defaultSpeed: Double { didSet { defaults.set(defaultSpeed, forKey: Self.defaultSpeedKey) } }
    var defaultVoiceBoost: Int { didSet { defaults.set(defaultVoiceBoost, forKey: Self.defaultBoostKey) } }
    var defaultSkipSilence: Bool { didSet { defaults.set(defaultSkipSilence, forKey: Self.defaultSkipSilenceKey) } }
    var defaultAdSkipMode: String { didSet { defaults.set(defaultAdSkipMode, forKey: Self.defaultAdSkipKey) } }
    var defaultAutoDownload: Bool { didSet { defaults.set(defaultAutoDownload, forKey: Self.defaultAutoDownloadKey) } }

    // MARK: Nitpicky details
    var seekForwardSec: Int { didSet { defaults.set(seekForwardSec, forKey: Self.seekForwardKey) } }
    var seekBackSec: Int { didSet { defaults.set(seekBackSec, forKey: Self.seekBackKey) } }
    var smartResumeEnabled: Bool { didSet { defaults.set(smartResumeEnabled, forKey: Self.smartResumeKey) } }
    var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: Self.autoplayNextKey) } }
    var seekAccelerationEnabled: Bool { didSet { defaults.set(seekAccelerationEnabled, forKey: Self.seekAccelKey) } }

    // MARK: Download policy
    var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: Self.wifiOnlyKey) } }
```

In `init`, after the existing loads:

```swift
        defaultSpeed = defaults.object(forKey: Self.defaultSpeedKey).flatMap { $0 as? Double } ?? 1.0
        defaultVoiceBoost = defaults.object(forKey: Self.defaultBoostKey).flatMap { $0 as? Int } ?? 0
        defaultSkipSilence = defaults.object(forKey: Self.defaultSkipSilenceKey).flatMap { $0 as? Bool } ?? false
        defaultAdSkipMode = defaults.string(forKey: Self.defaultAdSkipKey) ?? "off"
        defaultAutoDownload = defaults.object(forKey: Self.defaultAutoDownloadKey).flatMap { $0 as? Bool } ?? false
        seekForwardSec = defaults.object(forKey: Self.seekForwardKey).flatMap { $0 as? Int } ?? 30
        seekBackSec = defaults.object(forKey: Self.seekBackKey).flatMap { $0 as? Int } ?? 15
        smartResumeEnabled = defaults.object(forKey: Self.smartResumeKey).flatMap { $0 as? Bool } ?? true
        autoplayNext = defaults.object(forKey: Self.autoplayNextKey).flatMap { $0 as? Bool } ?? true
        seekAccelerationEnabled = defaults.object(forKey: Self.seekAccelKey).flatMap { $0 as? Bool } ?? true
        wifiOnlyDownloads = defaults.object(forKey: Self.wifiOnlyKey).flatMap { $0 as? Bool } ?? true
```

- [ ] **Step 4: `xcodegen generate`, run the test — PASS. Run `swiftlint lint` (type-body-length may need the key constants grouped; fix if flagged).**
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: global playback/nitpicky/download defaults in AppSettings"`

---

### Task 2: `ShowSettings` optional overrides + launch migration

**Files:**
- Modify: `Onda/Models/ShowSettings.swift`
- Create: `Onda/Models/ShowSettingsMigrator.swift`
- Modify: `Onda/OndaApp.swift` (run migration in `init`)
- Modify (compile fixes at call sites): `Onda/Services/FeedRefreshService.swift:39` (temporary `== true` already works), `OndaTests/PlaybackManagerTests.swift` (helper), any other `ShowSettings(` constructors found via `grep -rn "ShowSettings(" Onda OndaTests OndaUITests`
- Test: `OndaTests/ShowSettingsMigratorTests.swift` (create)

**Interfaces:**
- Produces: `ShowSettings.speed: Double?`, `voiceBoost: Int?`, `skipSilence: Bool?`, `adSkipMode: String?`, `autoDownload: Bool?` (nil = inherit global). `ShowSettings()` no-arg init with everything nil/0. `ShowSettings.makeDefault()` now returns all-nil settings.
- Produces: `ShowSettingsMigrator.normalizeAll(in: ModelContext, defaults: UserDefaults)` — one-shot, guarded by UserDefaults key `"showSettingsOverrideMigrationDone"`; and testable `ShowSettingsMigrator.normalize(_ s: ShowSettings)`.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ShowSettingsMigratorTests.swift`:

```swift
//  ShowSettingsMigratorTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class ShowSettingsMigratorTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func test_normalize_nilsOutOldHardcodedDefaults() {
        let s = ShowSettings()
        s.speed = 1.0; s.voiceBoost = 0; s.skipSilence = false
        s.adSkipMode = "off"; s.autoDownload = false
        ShowSettingsMigrator.normalize(s)
        XCTAssertNil(s.speed); XCTAssertNil(s.voiceBoost); XCTAssertNil(s.skipSilence)
        XCTAssertNil(s.adSkipMode); XCTAssertNil(s.autoDownload)
    }

    func test_normalize_keepsCustomizedValuesAsOverrides() {
        let s = ShowSettings()
        s.speed = 1.5; s.voiceBoost = 2; s.skipSilence = true
        s.adSkipMode = "auto"; s.autoDownload = true
        ShowSettingsMigrator.normalize(s)
        XCTAssertEqual(s.speed, 1.5); XCTAssertEqual(s.voiceBoost, 2)
        XCTAssertEqual(s.skipSilence, true); XCTAssertEqual(s.adSkipMode, "auto")
        XCTAssertEqual(s.autoDownload, true)
    }

    func test_normalizeAll_runsOnceAndSetsFlag() throws {
        let ctx = try makeContext()
        let suite = "MigratorTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = ShowSettings(); s.speed = 1.0
        ctx.insert(s); try ctx.save()
        ShowSettingsMigrator.normalizeAll(in: ctx, defaults: d)
        XCTAssertNil(s.speed)
        // Second run must be a no-op even if a default-valued row reappears.
        let s2 = ShowSettings(); s2.speed = 1.0
        ctx.insert(s2); try ctx.save()
        ShowSettingsMigrator.normalizeAll(in: ctx, defaults: d)
        XCTAssertEqual(s2.speed, 1.0)
    }
}
```

- [ ] **Step 2: Run — build fails (`ShowSettings()` no-arg, optional assignment, `ShowSettingsMigrator` missing).**

- [ ] **Step 3: Implement the model change**

Replace `ShowSettings.swift` body:

```swift
@Model
final class ShowSettings {
    // Playback overrides — nil inherits the AppSettings global default.
    var speed: Double?
    var voiceBoost: Int?        // 0 = Off, 1 = Med, 2 = High
    var skipSilence: Bool?
    var adSkipMode: String?     // "off" | "manual" | "auto"
    var autoDownload: Bool?
    var introTrimSec: Int
    var outroTrimSec: Int
    var notifMode: String       // "all" | "important" | "none"
    // Retention overrides — nil inherits the AppSettings global default.
    var maxDownloadsKeptOverride: Int?              // 0 = explicitly unlimited
    var autoDeleteListenedAfterDaysOverride: Int?   // -1 = explicitly off, 0 = immediately
    var autoTranscribeOnDownloadOverride: Bool?
    var keepTranscriptsOverride: Bool?
    var ttsVoiceIdentifier: String?   // Articles show only; nil = system default voice
    var podcast: Podcast?

    init(speed: Double? = nil, voiceBoost: Int? = nil, skipSilence: Bool? = nil,
         adSkipMode: String? = nil, autoDownload: Bool? = nil,
         introTrimSec: Int = 0, outroTrimSec: Int = 0, notifMode: String = "all") {
        self.speed = speed
        self.voiceBoost = voiceBoost
        self.skipSilence = skipSilence
        self.adSkipMode = adSkipMode
        self.autoDownload = autoDownload
        self.introTrimSec = introTrimSec
        self.outroTrimSec = outroTrimSec
        self.notifMode = notifMode
    }

    /// Fresh settings that inherit every global default (all overrides nil).
    static func makeDefault() -> ShowSettings { ShowSettings() }
}
```

Create `Onda/Models/ShowSettingsMigrator.swift`:

```swift
//  ShowSettingsMigrator.swift
//  One-time normalization after playback fields became optional overrides: a stored value equal
//  to the old hardcoded default means "the user never touched this", so it becomes nil (inherit)
//  and starts tracking the global default. Any other value is a real customization and stays.
import Foundation
import SwiftData

enum ShowSettingsMigrator {
    static let migrationFlagKey = "showSettingsOverrideMigrationDone"

    static func normalize(_ s: ShowSettings) {
        if s.speed == 1.0 { s.speed = nil }
        if s.voiceBoost == 0 { s.voiceBoost = nil }
        if s.skipSilence == false { s.skipSilence = nil }
        if s.adSkipMode == "off" { s.adSkipMode = nil }
        if s.autoDownload == false { s.autoDownload = nil }
    }

    @MainActor
    static func normalizeAll(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        let all = (try? context.fetch(FetchDescriptor<ShowSettings>())) ?? []
        for s in all { normalize(s) }
        try? context.save()
        defaults.set(true, forKey: migrationFlagKey)
    }
}
```

In `OndaApp.swift` `init`, immediately after `_appSettings = State(initialValue: settings)`:

```swift
            ShowSettingsMigrator.normalizeAll(in: c.mainContext)
```

- [ ] **Step 4: Fix compile fallout**

Run `grep -rn "ShowSettings(" Onda OndaTests OndaUITests` and `grep -rn "\.settings?\.\(speed\|voiceBoost\|skipSilence\|adSkipMode\|autoDownload\)\|s\.speed\|s\.voiceBoost" Onda OndaTests` — fix each site to compile with optionals. Known sites:
- `PlaybackManager.swift`: `settings?.speed ?? 1.0` → `settings?.speed ?? 1.0` still compiles because `speed` is now `Double?` and `settings?.speed` is `Double??` — Swift flattens `??` here; if the compiler complains use `settings?.speed ?? nil ?? 1.0` — **prefer `(settings?.speed ?? nil) ?? 1.0` only as a stopgap**; Task 4 replaces all these reads with the resolver anyway. Same for `voiceBoost`, `skipSilence == true` (works on `Bool??` via `== true`), `adSkipMode == "auto"` (works), `outroTrimSec`/`introTrimSec` unchanged (still non-optional).
- `FeedRefreshService.swift:39`: `podcast.settings?.autoDownload == true` still compiles.
- `NowPlayingView.swift` chips/cycle: `settings?.speed ?? 1` (flattening as above), `settings?.voiceBoost ?? 0`, `s.skipSilence.toggle()` → replace `toggleSilence`/`toggleBoost`/`setSpeed` bodies minimally so they compile (Task 7 rewrites them properly):
  `settings?.speed = speed` (fine), `$0.voiceBoost = (($0.voiceBoost ?? 0) + 1) % 3`, `$0.skipSilence = !($0.skipSilence ?? false)`.
- `ShowSettingsSheet.swift`: speed cycle `s.speed ?? 1`, boost `s.voiceBoost ?? 0` etc. — minimal compile fixes only; Task 8 redoes this UI.
- `OndaTests/PlaybackManagerTests.swift` `makeEpisode`: `s.speed = speed` still compiles.

- [ ] **Step 5: `xcodegen generate`; run `-only-testing:OndaTests/ShowSettingsMigratorTests` — PASS. Then run the full OndaTests suite to catch fallout: expect PASS.**
- [ ] **Step 6: Commit** — `git commit -am "feat: ShowSettings playback fields become optional overrides + one-time migration"`

---

### Task 3: `ResolvedPlaybackSettings`

**Files:**
- Create: `Onda/Playback/ResolvedPlaybackSettings.swift`
- Test: `OndaTests/ResolvedPlaybackSettingsTests.swift` (create)

**Interfaces:**
- Produces: `struct ResolvedPlaybackSettings { let speed: Double; let voiceBoost: Int; let skipSilence: Bool; let adSkipMode: String; let autoDownload: Bool; init(show: ShowSettings?, app: AppSettings) }` (`@MainActor` because `AppSettings` is).

- [ ] **Step 1: Write the failing test**

Create `OndaTests/ResolvedPlaybackSettingsTests.swift`:

```swift
//  ResolvedPlaybackSettingsTests.swift
import XCTest
@testable import Onda

@MainActor
final class ResolvedPlaybackSettingsTests: XCTestCase {
    private func makeApp() -> AppSettings {
        let suite = "ResolvedTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }

    func test_nilShow_inheritsEveryGlobal() {
        let app = makeApp()
        app.defaultSpeed = 1.5; app.defaultVoiceBoost = 1; app.defaultSkipSilence = true
        app.defaultAdSkipMode = "manual"; app.defaultAutoDownload = true
        let r = ResolvedPlaybackSettings(show: nil, app: app)
        XCTAssertEqual(r.speed, 1.5); XCTAssertEqual(r.voiceBoost, 1)
        XCTAssertTrue(r.skipSilence); XCTAssertEqual(r.adSkipMode, "manual")
        XCTAssertTrue(r.autoDownload)
    }

    func test_showOverride_winsPerField() {
        let app = makeApp()
        app.defaultSpeed = 1.5
        let s = ShowSettings()
        s.speed = 2.0           // overridden
        s.voiceBoost = nil      // inherited (0)
        let r = ResolvedPlaybackSettings(show: s, app: app)
        XCTAssertEqual(r.speed, 2.0)
        XCTAssertEqual(r.voiceBoost, 0)
    }
}
```

- [ ] **Step 2: Run — build fails (type missing).**
- [ ] **Step 3: Implement**

Create `Onda/Playback/ResolvedPlaybackSettings.swift`:

```swift
//  ResolvedPlaybackSettings.swift
//  The single resolution point for playback-affecting settings: per-show override (non-nil
//  ShowSettings field) wins, otherwise the AppSettings global default. Everything that acts on
//  these values — PlaybackManager, FeedRefreshService, the settings UI captions — goes through
//  this type rather than reading ShowSettings fields directly.
import Foundation

@MainActor
struct ResolvedPlaybackSettings {
    let speed: Double
    let voiceBoost: Int
    let skipSilence: Bool
    let adSkipMode: String
    let autoDownload: Bool

    init(show: ShowSettings?, app: AppSettings) {
        speed = show?.speed ?? app.defaultSpeed
        voiceBoost = show?.voiceBoost ?? app.defaultVoiceBoost
        skipSilence = show?.skipSilence ?? app.defaultSkipSilence
        adSkipMode = show?.adSkipMode ?? app.defaultAdSkipMode
        autoDownload = show?.autoDownload ?? app.defaultAutoDownload
    }
}
```

- [ ] **Step 4: `xcodegen generate`; run the test — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: ResolvedPlaybackSettings resolver (override ?? global)"`

---

### Task 4: `PlaybackManager` reads resolved settings

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`
- Modify: `Onda/OndaApp.swift:35` (pass `appSettings`)
- Modify: `OndaTests/PlaybackManagerTests.swift` (constructor calls; add a resolution test)

**Interfaces:**
- Consumes: `ResolvedPlaybackSettings`, `AppSettings` (Task 1, 3).
- Produces: `PlaybackManager.init(engine:modelContext:appSettings:)`; internal `var resolved: ResolvedPlaybackSettings` (read-only computed); `settings` (raw ShowSettings) stays for trim fields and UI writes.

- [ ] **Step 1: Write the failing test** (append to `PlaybackManagerTests`)

```swift
    func test_play_usesGlobalDefaultSpeed_whenShowHasNoOverride() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.defaultSpeed = 1.75
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep = makeEpisode(in: ctx)          // makeDefault() → all-nil overrides
        pm.play(ep)
        XCTAssertEqual(engine.rate, 1.75)
    }
```

Add the helper next to `makeContext()`:

```swift
    private func makeAppSettings() -> AppSettings {
        let suite = "PMTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return AppSettings(defaults: d)
    }
```

- [ ] **Step 2: Run `-only-testing:OndaTests/PlaybackManagerTests` — build fails (no `appSettings:` param).**
- [ ] **Step 3: Implement**

In `PlaybackManager`:
- Add `private let appSettings: AppSettings` and the init param `appSettings: AppSettings` (stored before the closures are set up).
- Add below the existing `settings` computed var:

```swift
    /// Effective playback settings for the current episode: per-show override ?? global default.
    var resolved: ResolvedPlaybackSettings {
        ResolvedPlaybackSettings(show: settings, app: appSettings)
    }
```

- Replace every effect read:
  - `play()`: `engine.rate = Float(resolved.speed)`
  - `restoreLastEpisode()`: `engine.rate = Float(resolved.speed)`
  - `applyAudioSettings()`: `engine.rate = Float(resolved.speed)`; `BoostLevel(clamping: resolved.voiceBoost)`; `if !resolved.skipSilence { silence.reset() }`; update the log line to use `resolved.speed` / `resolved.skipSilence`.
  - `onRMS` guard: `guard self.resolved.skipSilence else { ... }`
  - `handleTimeUpdate` ad branch: `resolved.adSkipMode == "auto"`
  - `nowPlaying.update(... rate: isPlaying ? Float(resolved.speed) : 0)`
  - Intro/outro trim reads (`settings?.introTrimSec`, `settings?.outroTrimSec`) stay as-is (non-optional Ints, not part of the defaults system).

In `OndaApp.swift:35`: `PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext, appSettings: settings)`.

In `PlaybackManagerTests`, update every `PlaybackManager(engine:modelContext:)` call to pass `appSettings: makeAppSettings()` (store one per test where behavior matters).

- [ ] **Step 4: Run full `OndaTests/PlaybackManagerTests` — PASS. Build the app target — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: PlaybackManager resolves effects through global defaults"`

---

### Task 5: Configurable seek intervals

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift` (skip entry points)
- Modify: `Onda/Playback/NowPlayingCenter.swift` (interval updates)
- Modify: `Onda/Player/NowPlayingView.swift:107-126` (transport buttons)
- Test: `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Consumes: `appSettings.seekForwardSec` / `seekBackSec` (Task 1).
- Produces: `PlaybackManager.skipForward()`, `PlaybackManager.skipBack()` (no-arg; used by UI and remote commands), `PlaybackManager.refreshSkipIntervals()`; `NowPlayingCenter.updateSkipIntervals(forward: Int, back: Int)`. `skip(by:)` remains for chapter/ad/silence internal seeks.

- [ ] **Step 1: Write the failing test**

```swift
    func test_skipForwardAndBack_useConfiguredIntervals() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.seekForwardSec = 45; app.seekBackSec = 10
        app.seekAccelerationEnabled = false
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep = makeEpisode(in: ctx, duration: 1000, position: 100)
        pm.play(ep)
        pm.skipForward()
        XCTAssertEqual(pm.positionSeconds, 145, accuracy: 0.01)
        pm.skipBack()
        XCTAssertEqual(pm.positionSeconds, 135, accuracy: 0.01)
    }
```

(`seekAccelerationEnabled = false` keeps this test valid after Task 6.)

- [ ] **Step 2: Run — fails (`skipForward` undefined).**
- [ ] **Step 3: Implement**

`NowPlayingCenter.swift` — add:

```swift
    /// Re-registers the lock-screen skip button intervals (called at startup and when the
    /// user changes the seek-interval setting).
    func updateSkipIntervals(forward: Int, back: Int) {
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: back)]
    }
```

`PlaybackManager` — in `init`, replace the hardcoded remote-command skips:

```swift
        nowPlaying.configureRemoteCommands(
            play: { [weak self] in self?.resumeExternally() },
            pause: { [weak self] in self?.pauseExternally() },
            skipForward: { [weak self] in self?.skipForward() },
            skipBack: { [weak self] in self?.skipBack() })
        refreshSkipIntervals()
```

Add near `skip(by:)`:

```swift
    /// User-facing skip actions (player buttons, lock screen). Use the configured intervals;
    /// internal seeks (ads, silence, chapters) still call `skip(by:)` directly.
    func skipForward() { skip(by: TimeInterval(appSettings.seekForwardSec)) }
    func skipBack() { skip(by: -TimeInterval(appSettings.seekBackSec)) }

    /// Pushes the configured intervals to the lock-screen remote commands.
    func refreshSkipIntervals() {
        nowPlaying.updateSkipIntervals(forward: appSettings.seekForwardSec,
                                       back: appSettings.seekBackSec)
    }
```

`NowPlayingView.swift` transport — replace the two skip buttons:

```swift
            Button { playback.skipBack() } label: { skipLabel(backSymbol) }
                .accessibilityLabel("Skip back \(appSettings.seekBackSec) seconds")
            ...
            Button { playback.skipForward() } label: { skipLabel(forwardSymbol) }
                .accessibilityLabel("Skip forward \(appSettings.seekForwardSec) seconds")
```

with `@Environment(AppSettings.self) private var appSettings` added to the view and:

```swift
    // SF Symbols ship goforward/gobackward variants for 10/15/30/45/60 — exactly our choices.
    private var forwardSymbol: String { "goforward.\(appSettings.seekForwardSec)" }
    private var backSymbol: String { "gobackward.\(appSettings.seekBackSec)" }
```

- [ ] **Step 4: Run PlaybackManagerTests — PASS. Build — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: configurable seek-forward/back intervals (player + lock screen)"`

---

### Task 6: Seek acceleration

**Files:**
- Create: `Onda/Playback/SeekAccelerator.swift`
- Modify: `Onda/Playback/PlaybackManager.swift` (`skipForward`/`skipBack`)
- Test: `OndaTests/SeekAcceleratorTests.swift` (create)

**Interfaces:**
- Produces: `struct SeekAccelerator { mutating func multiplier(direction: Int, now: Date) -> Double }` — consecutive same-direction calls within 2 s return 1, 2, 4, 4, …; a direction change or >2 s gap resets to 1.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/SeekAcceleratorTests.swift`:

```swift
//  SeekAcceleratorTests.swift
import XCTest
@testable import Onda

final class SeekAcceleratorTests: XCTestCase {
    func test_rapidSameDirectionTaps_growAndCapAt4x() {
        var a = SeekAccelerator()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0), 1)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(0.5)), 2)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(1.0)), 4)
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(1.5)), 4)
    }

    func test_gapOrDirectionChange_resets() {
        var a = SeekAccelerator()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = a.multiplier(direction: 1, now: t0)
        _ = a.multiplier(direction: 1, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(a.multiplier(direction: 1, now: t0.addingTimeInterval(3.0)), 1)   // gap
        _ = a.multiplier(direction: 1, now: t0.addingTimeInterval(3.2))
        XCTAssertEqual(a.multiplier(direction: -1, now: t0.addingTimeInterval(3.4)), 1)  // flip
    }
}
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**

Create `Onda/Playback/SeekAccelerator.swift`:

```swift
//  SeekAccelerator.swift
//  Overcast-style seek acceleration: repeated skip taps in the same direction within a short
//  window multiply the jump (1× → 2× → 4×, capped), so mashing the button covers ground fast.
import Foundation

struct SeekAccelerator {
    static let window: TimeInterval = 2.0
    private var lastTapAt: Date?
    private var lastDirection = 0
    private var multiplierValue = 1.0

    mutating func multiplier(direction: Int, now: Date) -> Double {
        if let last = lastTapAt, direction == lastDirection,
           now.timeIntervalSince(last) <= Self.window {
            multiplierValue = min(4, multiplierValue * 2)
        } else {
            multiplierValue = 1
        }
        lastTapAt = now
        lastDirection = direction
        return multiplierValue
    }
}
```

In `PlaybackManager`, add `private var seekAccelerator = SeekAccelerator()` and `var now: () -> Date = { .now }` (internal, injectable for tests), then update:

```swift
    func skipForward() {
        let mult = appSettings.seekAccelerationEnabled
            ? seekAccelerator.multiplier(direction: 1, now: now()) : 1
        skip(by: TimeInterval(appSettings.seekForwardSec) * mult)
    }
    func skipBack() {
        let mult = appSettings.seekAccelerationEnabled
            ? seekAccelerator.multiplier(direction: -1, now: now()) : 1
        skip(by: -TimeInterval(appSettings.seekBackSec) * mult)
    }
```

- [ ] **Step 4: Run SeekAcceleratorTests + PlaybackManagerTests — PASS (Task 5's test disabled acceleration, so it still passes).**
- [ ] **Step 5: Commit** — `git commit -am "feat: seek acceleration on repeated skip taps"`

---

### Task 7: Smart Resume

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`
- Test: `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Produces: `static PlaybackManager.smartResumeRewind(afterPauseOf: TimeInterval) -> TimeInterval` (pure: <60 s → 0; <30 min → 5; <3 h → 15; else 30). Pause timestamps tracked in `togglePlayPause`; rewind applied on resume when `appSettings.smartResumeEnabled`.

- [ ] **Step 1: Write the failing tests**

```swift
    func test_smartResumeRewind_scalesWithPauseLength() {
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 30), 0)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 5 * 60), 5)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 60 * 60), 15)
        XCTAssertEqual(PlaybackManager.smartResumeRewind(afterPauseOf: 5 * 3600), 30)
    }

    func test_resumeAfterLongPause_rewindsWhenSmartResumeOn() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()   // smartResumeEnabled defaults to true
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        pm.now = { clock }
        let ep = makeEpisode(in: ctx, duration: 1000, position: 500)
        pm.play(ep)
        pm.togglePlayPause()                      // pause at 500
        clock = clock.addingTimeInterval(10 * 60) // 10 minutes later
        pm.togglePlayPause()                      // resume
        XCTAssertEqual(pm.positionSeconds, 495, accuracy: 0.01)   // 5s rewind
    }

    func test_resumeAfterShortPause_doesNotRewind() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: makeAppSettings())
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        pm.now = { clock }
        let ep = makeEpisode(in: ctx, duration: 1000, position: 500)
        pm.play(ep)
        pm.togglePlayPause()
        clock = clock.addingTimeInterval(20)
        pm.togglePlayPause()
        XCTAssertEqual(pm.positionSeconds, 500, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**

In `PlaybackManager`, add `private var pausedAt: Date?` and:

```swift
    /// Smart Resume rewind: after a break, back up a little so the listener regains context.
    /// Fixed internal thresholds (not user-tunable); the feature toggle lives in AppSettings.
    static func smartResumeRewind(afterPauseOf pause: TimeInterval) -> TimeInterval {
        switch pause {
        case ..<60: 0
        case ..<(30 * 60): 5
        case ..<(3 * 3600): 15
        default: 30
        }
    }
```

Replace `togglePlayPause()`:

```swift
    func togglePlayPause() {
        guard currentEpisode != nil else { return }
        if isPlaying {
            engine.pause(); persistPosition()
            pausedAt = now()
        } else {
            if appSettings.smartResumeEnabled, let pausedAt {
                let rewind = Self.smartResumeRewind(afterPauseOf: now().timeIntervalSince(pausedAt))
                if rewind > 0 {
                    let target = max(0, positionSeconds - rewind)
                    engine.seek(to: target); positionSeconds = target
                }
            }
            pausedAt = nil
            engine.play()
        }
        isPlaying.toggle()
    }
```

Also clear `pausedAt = nil` at the top of `play(_:)` (a new episode isn't a resume).

- [ ] **Step 4: Run PlaybackManagerTests — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: Smart Resume — rewind scaled to pause length"`

*(Silence-snap phase 2 from the spec is deliberately deferred; the toggle's meaning is unchanged.)*

---

### Task 8: Autoplay-next toggle

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift` (`handleEndOfItem`)
- Test: `OndaTests/PlaybackManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
    func test_episodeEnd_stopsInsteadOfAdvancing_whenAutoplayOff() throws {
        let ctx = try makeContext()
        let engine = FakeEngine()
        let app = makeAppSettings()
        app.autoplayNext = false
        let pm = PlaybackManager(engine: engine, modelContext: ctx, appSettings: app)
        let ep1 = makeEpisode(in: ctx, guid: "a")
        let ep2 = makeEpisode(in: ctx, guid: "b")
        pm.play(ep1)
        pm.enqueue(ep2)
        engine.emitEnd()
        XCTAssertFalse(pm.isPlaying)
        XCTAssertTrue(ep1.played)
        XCTAssertEqual(pm.queue.count, 1)          // queue untouched
        XCTAssertEqual(pm.currentEpisode?.guid, "a")
    }
```

- [ ] **Step 2: Run — fails (it advances to "b").**
- [ ] **Step 3: Implement** — in `handleEndOfItem()`, after the sleep-timer branch:

```swift
        if !appSettings.autoplayNext {
            isPlaying = false
            return
        }
        playNextInQueue()
```

- [ ] **Step 4: Run PlaybackManagerTests — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: autoplay-next toggle (stop at episode end when off)"`

---

### Task 9: Auto-download resolves through the global default

**Files:**
- Modify: `Onda/Services/FeedRefreshService.swift` (init + `refreshAll`)
- Modify: `Onda/OndaApp.swift:63` (pass `appSettings`)
- Test: `OndaTests/FeedRefreshServiceTests.swift`

**Interfaces:**
- Produces: `FeedRefreshService.init(modelContext:subscriptions:downloads:appSettings:)`; auto-download decision becomes `ResolvedPlaybackSettings(show: podcast.settings, app: appSettings).autoDownload`.

- [ ] **Step 1: Write the failing test** — open `OndaTests/FeedRefreshServiceTests.swift`, mirror its existing construction pattern (read the file first; it already fakes `SubscriptionService`/`DownloadManager` or uses seams — follow suit) and add:

```swift
    func test_refreshAll_autoDownloads_whenGlobalDefaultOn_andShowHasNoOverride() async throws {
        // Arrange a subscribed podcast whose settings.autoDownload is nil, appSettings
        // defaultAutoDownload = true; refresh; assert downloads.download was invoked for
        // the new episode. Use the file's existing fake/spy types.
    }
```

Write the real test against whatever seams the file already uses (`newEpisodesAfterRefresh` is a pure seam if full refresh isn't fakeable — acceptable fallback: unit-test the resolution condition via `ResolvedPlaybackSettings` and assert `FeedRefreshService` compiles against it; prefer the spy if one exists).

- [ ] **Step 2: Run — fails (init signature).**
- [ ] **Step 3: Implement** — add `private let appSettings: AppSettings` + init param; change the condition in `refreshAll`:

```swift
                if ResolvedPlaybackSettings(show: podcast.settings, app: appSettings).autoDownload {
```

Update `OndaApp.swift`: `FeedRefreshService(modelContext: c.mainContext, subscriptions: subs, downloads: dm, appSettings: settings)`. Update all `FeedRefreshService(` constructions in tests.

- [ ] **Step 4: Run FeedRefreshServiceTests — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: auto-download inherits global default"`

---

### Task 10: Wi-Fi-only downloads

**Files:**
- Modify: `Onda/Downloads/DownloadManager.swift`
- Modify: `Onda/OndaApp.swift` (wire the closure)
- Test: `OndaTests/DownloadManagerTests.swift`

**Interfaces:**
- Produces: `URLSessionProtocol` gains `func downloadTask(with request: URLRequest) -> URLSessionDownloadTask`; `DownloadManager.cellularAllowed: () -> Bool` (defaults `{ true }`); every download task is created from a `URLRequest` with `allowsCellularAccess = cellularAllowed()`. Per-request gating means no session teardown when the toggle flips.

- [ ] **Step 1: Write the failing test** — read `OndaTests/DownloadManagerTests.swift` first; it injects a fake `URLSessionProtocol`. Extend the fake to record the last `URLRequest`, then:

```swift
    func test_download_disallowsCellular_whenWifiOnly() throws {
        // dm.cellularAllowed = { false }
        // dm.download(episode)
        // XCTAssertEqual(fakeSession.lastRequest?.allowsCellularAccess, false)
    }

    func test_download_allowsCellular_byDefault() throws {
        // default closure — lastRequest?.allowsCellularAccess == true
    }
```

(Write these fully against the file's actual fake types.)

- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement**

```swift
protocol URLSessionProtocol { func downloadTask(with request: URLRequest) -> URLSessionDownloadTask }
```

In `DownloadManager`: add `var cellularAllowed: () -> Bool = { true }` and a helper:

```swift
    private func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = cellularAllowed()
        return request
    }
```

Replace the three `session.downloadTask(with: <url>)` calls (`download`, `handleFailed` retry, `retryManually`) with `session.downloadTask(with: makeRequest(for: url))`. In the delegate, `downloadTask.originalRequest?.url` still resolves the guid — unchanged.

In `OndaApp.swift` `init`, after `_downloads = State(initialValue: dm)`:

```swift
            dm.cellularAllowed = { !settings.wifiOnlyDownloads }
```

(`settings` is captured strongly by the closure; both live for the app's lifetime.)

- [ ] **Step 4: Run DownloadManagerTests — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: Wi-Fi-only download policy (per-request cellular gate)"`

---

### Task 11: Per-show sheet — playback rows become overrides

**Files:**
- Modify: `Onda/Settings/ShowSettingsSheet.swift`
- Modify: `Onda/Player/NowPlayingView.swift` (chips read resolved values)

No new unit tests (pure SwiftUI); behavior verified in Task 13. Keep `swiftlint` clean — the sheet is near the file-length budget, so extract subviews if flagged.

- [ ] **Step 1: Rework the Playback + Ads & Downloads sections**

Using the existing `boolOverridePicker` / `defaultCaption` helpers:

- **Speed** — three-way: Default / Custom via `SegmentedRow(options: [("Default", 0), ("Custom", 1)], selection: s.speed == nil ? 0 : 1)`; selecting Custom sets `s.speed = appSettings.defaultSpeed` (a concrete starting point), Default sets `s.speed = nil`. When custom, show the existing cycle button bound to `s.speed ?? 1`. Caption when default: `defaultCaption(NowPlayingView.speedText(appSettings.defaultSpeed), shown: s.speed == nil)`.
- **Voice Boost** — `SegmentedRow(options: [("Default", -1), ("Off", 0), ("Med", 1), ("High", 2)], selection: s.voiceBoost ?? -1) { s.voiceBoost = $0 == -1 ? nil : $0; playback.applyAudioSettings() }` + caption `["Off", "Med", "High"][appSettings.defaultVoiceBoost]`.
- **Skip Silence** — replace the Toggle with `boolOverridePicker("Skip Silence", defaultHint: appSettings.defaultSkipSilence ? "On" : "Off", value: Binding(get: { s.skipSilence }, set: { s.skipSilence = $0; playback.applyAudioSettings() }))`.
- **Ad Skip** — `SegmentedRow(options: [("Default", "default"), ("Off", "off"), ("Manual", "manual"), ("Auto", "auto")], selection: s.adSkipMode ?? "default") { s.adSkipMode = $0 == "default" ? nil : $0 }` + caption from `appSettings.defaultAdSkipMode` capitalized.
- **Auto-Download** — replace the Toggle with `boolOverridePicker("Auto-Download New Episodes", defaultHint: appSettings.defaultAutoDownload ? "On" : "Off", value: Binding(get: { s.autoDownload }, set: { s.autoDownload = $0 }))`.
- Speed cycle helper: `cycleSpeed()` operates on `s.speed ?? appSettings.defaultSpeed` and always writes back a concrete value; call `playback.applyAudioSettings()` after.

- [ ] **Step 2: Now Playing chips read resolved, write overrides**

In `NowPlayingView`, add `@Environment(AppSettings.self) private var appSettings` (already added in Task 5) and a `private var resolved: ResolvedPlaybackSettings? { ep.map { _ in ResolvedPlaybackSettings(show: settings, app: appSettings) } }`. Update:
- speed chip label/active: `resolved?.speed ?? 1`
- boost chip: `resolved?.voiceBoost ?? 0`
- silence chip: `resolved?.skipSilence == true`
- `cycleSpeed()`: index from `resolved?.speed`; `setSpeed` unchanged (writes override).
- `toggleBoost()`: `$0.voiceBoost = ((resolved?.voiceBoost ?? 0) + 1) % 3`
- `toggleSilence()`: `$0.skipSilence = !(resolved?.skipSilence ?? false)`
- ad banner checks: `resolved?.adSkipMode`.

- [ ] **Step 3: Build + `swiftlint lint` — clean. Run full OndaTests — PASS.**
- [ ] **Step 4: Commit** — `git commit -am "feat: per-show sheet + player chips use default/override model"`

---

### Task 12: Profile UI — global Playback section, delete-played presets, Wi-Fi toggle

**Files:**
- Create: `Onda/Profile/PlaybackSettingsSection.swift`
- Modify: `Onda/Shell/ProfileView.swift` (insert section)
- Modify: `Onda/Profile/RetentionSettingsSection.swift` (presets + Wi-Fi toggle)

- [ ] **Step 1: Create `PlaybackSettingsSection`** — same shape as `RetentionSettingsSection` (header + `BrutalCard`, `toggleRow`/`SegmentedRow` idioms):

```swift
//  PlaybackSettingsSection.swift
//  Global playback defaults + nitpicky details shown in ProfileView. Per-show overrides live
//  in ShowSettingsSheet; these are the values a show inherits when it has no override.
import SwiftUI

struct PlaybackSettingsSection: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppSettings.self) private var appSettings
    @Environment(PlaybackManager.self) private var playback

    private static let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    private static let seekChoices = [10, 15, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            BrutalCard {
                VStack(alignment: .leading, spacing: 0) {
                    labeledRow("Speed") {
                        Button(NowPlayingView.speedText(appSettings.defaultSpeed)) { cycleSpeed() }
                            .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
                    }
                    divider
                    segmented("Voice Boost", options: [("Off", 0), ("Med", 1), ("High", 2)],
                              selection: appSettings.defaultVoiceBoost) {
                        appSettings.defaultVoiceBoost = $0; playback.applyAudioSettings()
                    }
                    divider
                    toggleRow("Skip Silence", isOn: Binding(
                        get: { appSettings.defaultSkipSilence },
                        set: { appSettings.defaultSkipSilence = $0; playback.applyAudioSettings() }))
                    divider
                    segmented("Ad Skip", options: [("Off", "off"), ("Manual", "manual"), ("Auto", "auto")],
                              selection: appSettings.defaultAdSkipMode) { appSettings.defaultAdSkipMode = $0 }
                    divider
                    segmented("Skip Forward", options: Self.seekChoices.map { ("\($0)s", $0) },
                              selection: appSettings.seekForwardSec) {
                        appSettings.seekForwardSec = $0; playback.refreshSkipIntervals()
                    }
                    divider
                    segmented("Skip Back", options: Self.seekChoices.map { ("\($0)s", $0) },
                              selection: appSettings.seekBackSec) {
                        appSettings.seekBackSec = $0; playback.refreshSkipIntervals()
                    }
                    divider
                    toggleRow("Smart Resume", subtitle: "Rewind a little after a break",
                              isOn: Binding(get: { appSettings.smartResumeEnabled },
                                            set: { appSettings.smartResumeEnabled = $0 }))
                    divider
                    toggleRow("Autoplay Next", subtitle: "Continue to the queue when an episode ends",
                              isOn: Binding(get: { appSettings.autoplayNext },
                                            set: { appSettings.autoplayNext = $0 }))
                    divider
                    toggleRow("Seek Acceleration", subtitle: "Repeated skips jump farther",
                              isOn: Binding(get: { appSettings.seekAccelerationEnabled },
                                            set: { appSettings.seekAccelerationEnabled = $0 }))
                }
                .padding(16)
            }
        }
    }

    private func cycleSpeed() {
        let steps = Self.speedSteps
        let i = steps.firstIndex(of: appSettings.defaultSpeed) ?? 1
        appSettings.defaultSpeed = steps[(i + 1) % steps.count]
        playback.applyAudioSettings()
    }
    // + divider / toggleRow / labeledRow / segmented helpers copied from
    //   RetentionSettingsSection's private helpers (same visual style; keep subtitle optional).
}
```

Write the four small private helpers concretely (copy `divider`, `toggleRow` — give it an optional `subtitle: String? = nil` — from `RetentionSettingsSection.swift:57-71`; `labeledRow` is an HStack title + trailing content; `segmented` is a titled `SegmentedRow`).

- [ ] **Step 2: Insert in `ProfileView`** — after the Appearance card, before `RetentionSettingsSection()`:

```swift
                    PlaybackSettingsSection()
```

- [ ] **Step 3: Delete-played presets + Wi-Fi toggle in `RetentionSettingsSection`**

Replace the "Auto-delete listened" toggle+stepper block with a preset row:

```swift
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete Played Episodes").scaledFont(15, weight: .semibold)
                            .foregroundStyle(theme.color(.text))
                        SegmentedRow(options: [("Never", -1), ("Done", 0), ("1 day", 1), ("Custom", 7)],
                                     selection: presetSelection) {
                            appSettings.defaultAutoDeleteListenedAfterDays = $0
                        }
                        if appSettings.defaultAutoDeleteListenedAfterDays > 1 {
                            stepperRow("After",
                                       value: Binding(get: { appSettings.defaultAutoDeleteListenedAfterDays },
                                                      set: { appSettings.defaultAutoDeleteListenedAfterDays = $0 }),
                                       range: 2...30, label: { "\($0) days" })
                        }
                    }
```

with:

```swift
    /// Maps the stored day count onto the preset segments; any value ≥ 2 selects "Custom".
    private var presetSelection: Int {
        let d = appSettings.defaultAutoDeleteListenedAfterDays
        return d >= 2 ? 7 : d
    }
```

(Note the "Custom" segment carries sentinel value 7 — tapping it stores 7 days and reveals the stepper. Engine semantics unchanged: -1 off, 0 immediate, N days.)

Add at the top of the card, above "Limit downloads kept":

```swift
                    toggleRow("Wi-Fi Only Downloads", subtitle: "Never download over cellular",
                              isOn: Binding(get: { appSettings.wifiOnlyDownloads },
                                            set: { appSettings.wifiOnlyDownloads = $0 }))
                    divider
```

- [ ] **Step 4: `xcodegen generate`; build + `swiftlint lint` — clean.**
- [ ] **Step 5: Commit** — `git commit -am "feat: Profile playback/nitpicky section, delete-played presets, Wi-Fi-only toggle"`

---

### Task 13: Full verification

- [ ] **Step 1: Full test suite** — `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`. Expected: all green (unit + UI tests — UI tests exercise the settings sheet; fix any that assumed the old Toggle controls).
- [ ] **Step 2: `swiftlint lint`** — 0 violations.
- [ ] **Step 3: Simulator walkthrough via the `verify` skill**: change global speed → play an un-customized show → speed applies; set a per-show override → global change no longer affects it; seek buttons show/jump the configured interval (check lock screen too); pause 2+ min → resume rewinds ~5 s; autoplay off → playback stops at end; Wi-Fi-only toggle flips; delete-played presets render.
- [ ] **Step 4: Commit any fixes; update the spec's Status line to Implemented.**
