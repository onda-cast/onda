# Onda Plan 4: Audio DSP (Voice Boost + Skip Silence + Ad Banner) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Voice Boost and Skip Silence chips actually process audio, via an `MTAudioProcessingTap` attached to the `AVPlayerItem`; and render the Now Playing ad banner only when a real Podcasting-2.0 ad-marked chapter is active.

**Architecture:** A single `MTAudioProcessingTap` runs in `AVPlayerItem.audioMix`. Its C process callback (1) applies a scalar gain (Voice Boost) and (2) measures per-buffer RMS energy for Skip Silence. All *decisions* (what gain a boost level maps to; whether a run of low-energy buffers should trigger a skip; whether the current position is inside an ad chapter) live in pure Swift value types that are unit-tested with synthetic buffers — the C callback and `AVPlayer` seek are thin glue. This isolates the risky real-time code from the testable logic.

**Tech Stack:** Swift 6, AVFoundation (`MTAudioProcessingTap`, `AVMutableAudioMix`), Accelerate (vDSP for RMS), XCTest.

## Global Constraints

- Deployment target iOS 17.0 (Plan 1 Global Constraints apply verbatim).
- Audio DSP path is `AVPlayer` + `MTAudioProcessingTap` **only**. `AVAudioEngine` is not used.
- Canonical timeline preserved: Skip Silence triggers an `AVPlayer` seek in feed-seconds; it never alters stored positions except via the normal seek path.
- All decision logic (`BoostLevel.gain`, `SilenceDetector`, `AdWindow`) is pure and unit-tested against synthetic input; no test instantiates a real tap or player.
- Skip Silence is accepted as coarse (buffering latency) per the spec's Open Risks; thresholds are tunable constants in one place.

**Depends on:** Plans 1–3 complete (`PlaybackManager`, `PlayerEngine`/`AVPlayerEngine`, `ShowSettings`, `ChapterFetcher`, `Chapter`).

---

## File Structure

```
Onda/
  Playback/
    AudioTap.swift          — MTAudioProcessingTap creation + C callbacks (glue)
    BoostLevel.swift        — voiceBoost Int → gain scalar (pure)
    SilenceDetector.swift   — RMS run-length → shouldSkip decision (pure)
    AdWindow.swift          — is position inside an ad chapter? (pure)
    AVPlayerEngine.swift    — MODIFY (in PlayerEngine.swift): expose current AVPlayerItem + install tap
    PlaybackManager.swift   — MODIFY: push boost/silence settings into the tap; expose adActive
  Player/
    NowPlayingView.swift    — MODIFY: render ad banner when playback.adActive
OndaTests/
  BoostLevelTests.swift
  SilenceDetectorTests.swift
  AdWindowTests.swift
```

---

### Task 1: BoostLevel (pure gain mapping)

**Files:**
- Create: `Onda/Playback/BoostLevel.swift`, `OndaTests/BoostLevelTests.swift`

**Interfaces:**
- Consumes: `ShowSettings.voiceBoost: Int` (0/1/2).
- Produces: `enum BoostLevel: Int { case off = 0, medium = 1, high = 2 }` with `var gain: Float` (`off→1.0`, `medium→1.6`, `high→2.4`) and `init(clamping:)`.

- [ ] **Step 1: Write the failing test**

Create `OndaTests/BoostLevelTests.swift`:

```swift
//  BoostLevelTests.swift
import XCTest
@testable import Onda

final class BoostLevelTests: XCTestCase {
    func test_gainPerLevel() {
        XCTAssertEqual(BoostLevel.off.gain, 1.0)
        XCTAssertEqual(BoostLevel.medium.gain, 1.6, accuracy: 0.001)
        XCTAssertEqual(BoostLevel.high.gain, 2.4, accuracy: 0.001)
    }
    func test_clampingOutOfRange() {
        XCTAssertEqual(BoostLevel(clamping: -1), .off)
        XCTAssertEqual(BoostLevel(clamping: 5), .high)
        XCTAssertEqual(BoostLevel(clamping: 1), .medium)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/BoostLevelTests`
Expected: FAIL — `cannot find 'BoostLevel' in scope`.

- [ ] **Step 3: Write BoostLevel**

Create `Onda/Playback/BoostLevel.swift`:

```swift
//  BoostLevel.swift
import Foundation

enum BoostLevel: Int {
    case off = 0, medium = 1, high = 2

    init(clamping raw: Int) { self = BoostLevel(rawValue: max(0, min(2, raw))) ?? .off }

    var gain: Float {
        switch self {
        case .off: return 1.0
        case .medium: return 1.6
        case .high: return 2.4
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/BoostLevelTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/BoostLevel.swift OndaTests/BoostLevelTests.swift
git commit -m "feat: BoostLevel gain mapping"
```

---

### Task 2: SilenceDetector (pure RMS run-length decision)

**Files:**
- Create: `Onda/Playback/SilenceDetector.swift`, `OndaTests/SilenceDetectorTests.swift`

**Interfaces:**
- Consumes: per-buffer RMS values + buffer durations pushed from the tap.
- Produces:
  - `struct SilenceDetector` with tunable `rmsThreshold: Float = 0.02`, `minSilenceSeconds: Double = 0.6`
  - `mutating func consume(rms: Float, bufferSeconds: Double) -> Skip?` where `struct Skip { let seconds: Double }` is returned once when a silence run first exceeds `minSilenceSeconds` (the amount to jump), then suppressed until sound resumes.
  - `mutating func reset()`

- [ ] **Step 1: Write failing tests**

Create `OndaTests/SilenceDetectorTests.swift`:

```swift
//  SilenceDetectorTests.swift
import XCTest
@testable import Onda

final class SilenceDetectorTests: XCTestCase {
    func test_shortSilence_doesNotSkip() {
        var d = SilenceDetector()
        // 0.5s total quiet (< 0.6s threshold) across 5 buffers of 0.1s
        for _ in 0..<5 { XCTAssertNil(d.consume(rms: 0.001, bufferSeconds: 0.1)) }
    }

    func test_sustainedSilence_emitsSingleSkip() {
        var d = SilenceDetector()
        var skips: [SilenceDetector.Skip] = []
        for _ in 0..<10 { if let s = d.consume(rms: 0.001, bufferSeconds: 0.1) { skips.append(s) } }
        XCTAssertEqual(skips.count, 1, "one skip per silence run, not per buffer")
        XCTAssertGreaterThanOrEqual(skips[0].seconds, 0.6)
    }

    func test_soundResets_allowsNextSkip() {
        var d = SilenceDetector()
        var count = 0
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        _ = d.consume(rms: 0.5, bufferSeconds: 0.1)  // loud → reset run
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        XCTAssertEqual(count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/SilenceDetectorTests`
Expected: FAIL — `cannot find 'SilenceDetector' in scope`.

- [ ] **Step 3: Write SilenceDetector**

Create `Onda/Playback/SilenceDetector.swift`:

```swift
//  SilenceDetector.swift
import Foundation

struct SilenceDetector {
    var rmsThreshold: Float = 0.02
    var minSilenceSeconds: Double = 0.6

    struct Skip { let seconds: Double }

    private var runSeconds: Double = 0
    private var emittedForRun = false

    mutating func reset() { runSeconds = 0; emittedForRun = false }

    /// Returns a Skip exactly once, when a continuous quiet run first crosses the threshold.
    mutating func consume(rms: Float, bufferSeconds: Double) -> Skip? {
        if rms < rmsThreshold {
            runSeconds += bufferSeconds
            if runSeconds >= minSilenceSeconds && !emittedForRun {
                emittedForRun = true
                return Skip(seconds: runSeconds)
            }
            return nil
        } else {
            runSeconds = 0
            emittedForRun = false
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/SilenceDetectorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/SilenceDetector.swift OndaTests/SilenceDetectorTests.swift
git commit -m "feat: SilenceDetector RMS run-length decision (one skip per run)"
```

---

### Task 3: AdWindow (pure ad-position test)

**Files:**
- Create: `Onda/Playback/AdWindow.swift`, `OndaTests/AdWindowTests.swift`

**Interfaces:**
- Consumes: `[Chapter]` (sorted by start), current feed-seconds position, episode duration.
- Produces:
  - `struct AdWindow { init(chapters: [(start: TimeInterval, isAd: Bool)], duration: TimeInterval); func isAd(at seconds: TimeInterval) -> Bool; func adEnd(at seconds: TimeInterval) -> TimeInterval? }`
  - `adEnd` returns the start of the next non-ad chapter (or duration) when currently inside an ad — used by "auto" ad-skip to jump.

- [ ] **Step 1: Write failing tests**

Create `OndaTests/AdWindowTests.swift`:

```swift
//  AdWindowTests.swift
import XCTest
@testable import Onda

final class AdWindowTests: XCTestCase {
    private func window() -> AdWindow {
        AdWindow(chapters: [(0, false), (600, true), (780, false)], duration: 2292)
    }
    func test_isAd_insideAdChapter() {
        let w = window()
        XCTAssertFalse(w.isAd(at: 100))
        XCTAssertTrue(w.isAd(at: 650))
        XCTAssertFalse(w.isAd(at: 900))
    }
    func test_adEnd_returnsNextNonAdStart() {
        let w = window()
        XCTAssertEqual(w.adEnd(at: 650), 780)
        XCTAssertNil(w.adEnd(at: 100))
    }
    func test_trailingAd_endsAtDuration() {
        let w = AdWindow(chapters: [(0, false), (2000, true)], duration: 2292)
        XCTAssertEqual(w.adEnd(at: 2100), 2292)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/AdWindowTests`
Expected: FAIL — `cannot find 'AdWindow' in scope`.

- [ ] **Step 3: Write AdWindow**

Create `Onda/Playback/AdWindow.swift`:

```swift
//  AdWindow.swift
import Foundation

struct AdWindow {
    private let sorted: [(start: TimeInterval, isAd: Bool)]
    private let duration: TimeInterval

    init(chapters: [(start: TimeInterval, isAd: Bool)], duration: TimeInterval) {
        self.sorted = chapters.sorted { $0.start < $1.start }
        self.duration = duration
    }

    private func index(at seconds: TimeInterval) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var idx: Int? = nil
        for (i, c) in sorted.enumerated() where c.start <= seconds { idx = i }
        return idx
    }

    func isAd(at seconds: TimeInterval) -> Bool {
        guard let i = index(at: seconds) else { return false }
        return sorted[i].isAd
    }

    /// If currently inside an ad, the feed-second where the ad ends (next non-ad start, or duration).
    func adEnd(at seconds: TimeInterval) -> TimeInterval? {
        guard let i = index(at: seconds), sorted[i].isAd else { return nil }
        for j in (i + 1)..<sorted.count where !sorted[j].isAd { return sorted[j].start }
        return duration
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/AdWindowTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/AdWindow.swift OndaTests/AdWindowTests.swift
git commit -m "feat: AdWindow pure ad-position/ad-end logic"
```

---

### Task 4: The audio processing tap

**Files:**
- Create: `Onda/Playback/AudioTap.swift`
- Modify: `Onda/Playback/PlayerEngine.swift`

**Interfaces:**
- Consumes: `BoostLevel.gain`, and a callback for RMS values.
- Produces:
  - `final class AudioTap` wrapping an `MTAudioProcessingTap`; `var gain: Float` (thread-safe via atomic-ish set), `var onRMS: ((Float, Double) -> Void)?`, and `func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix`.
  - `AVPlayerEngine` gains: `func installTap() -> AudioTap` — builds the mix from the current item's first audio track and assigns `item.audioMix`; exposes `var currentItem: AVPlayerItem?`.

> The tap's C `process` callback applies gain in place and computes RMS via `vDSP_rmsqv`, then hops to the main queue to call `onRMS`. Gain is read from a boxed pointer so the Swift side can update it without re-creating the tap.

- [ ] **Step 1: Write the tap**

Create `Onda/Playback/AudioTap.swift`:

```swift
//  AudioTap.swift
import AVFoundation
import Accelerate

final class AudioTap {
    // Boxed state the C callbacks read/write via the tap's clientInfo.
    final class Storage {
        var gain: Float = 1.0
        var onRMS: ((Float, Double) -> Void)?
        var sampleRate: Double = 44_100
    }
    let storage = Storage()
    private(set) var audioMix: AVAudioMix?

    var gain: Float {
        get { storage.gain }
        set { storage.gain = newValue }
    }
    var onRMS: ((Float, Double) -> Void)? {
        get { storage.onRMS }
        set { storage.onRMS = newValue }
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(storage).toOpaque()),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare,
            unprepare: nil, process: tapProcess)

        var tap: Unmanaged<MTAudioProcessingTap>?
        MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                   kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap?.takeRetainedValue()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        audioMix = mix
        return mix
    }
}

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                     _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    let raw = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTap.Storage>.fromOpaque(raw).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let raw = MTAudioProcessingTapGetStorage(tap)
    let storage = Unmanaged<AudioTap.Storage>.fromOpaque(raw).takeUnretainedValue()
    storage.sampleRate = format.pointee.mSampleRate
}

private func tapProcess(_ tap: MTAudioProcessingTap, _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                     flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let raw = MTAudioProcessingTapGetStorage(tap)
    let storage = Unmanaged<AudioTap.Storage>.fromOpaque(raw).takeUnretainedValue()
    let gain = storage.gain

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var sumRMS: Float = 0; var bufCount = 0
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = data.assumingMemoryBound(to: Float.self)
        if gain != 1.0 { vDSP_vsmul(ptr, 1, [gain], ptr, 1, vDSP_Length(count)) }
        var rms: Float = 0; vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
        sumRMS += rms; bufCount += 1
    }
    let avgRMS = bufCount > 0 ? sumRMS / Float(bufCount) : 0
    let seconds = Double(numberFrames) / storage.sampleRate
    if let cb = storage.onRMS {
        DispatchQueue.main.async { cb(avgRMS, seconds) }
    }
}
```

- [ ] **Step 2: Expose tap installation on AVPlayerEngine**

Modify `Onda/Playback/PlayerEngine.swift`. Add to the `PlayerEngine` protocol:
```swift
    func setBoostGain(_ gain: Float)
    var onRMS: ((Float, Double) -> Void)? { get set }
```
In `AVPlayerEngine`, hold an `AudioTap?` and install it when loading an item:

```swift
    private var tap: AudioTap?
    var onRMS: ((Float, Double) -> Void)?

    func setBoostGain(_ gain: Float) { tap?.gain = gain }
```
Extend `load(url:startAt:)` — after creating `item` and before `replaceCurrentItem`, install the tap once the asset's audio track loads:

```swift
        Task {
            if let track = try? await item.asset.loadTracks(withMediaCharacteristic: .audible).first {
                let t = AudioTap()
                t.gain = 1.0
                t.onRMS = { [weak self] rms, secs in self?.onRMS?(rms, secs) }
                item.audioMix = t.makeAudioMix(for: track)
                self.tap = t
            }
        }
```

Add the default no-op to `FakeEngine` in `OndaTests/PlaybackManagerTests.swift`:
```swift
    var onRMS: ((Float, Double) -> Void)?
    func setBoostGain(_ gain: Float) {}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Onda/Playback/AudioTap.swift Onda/Playback/PlayerEngine.swift OndaTests/PlaybackManagerTests.swift
git commit -m "feat: MTAudioProcessingTap (gain + RMS) installed on AVPlayerItem audioMix"
```

---

### Task 5: Wire boost + skip-silence + ad detection into PlaybackManager

**Files:**
- Modify: `Onda/Playback/PlaybackManager.swift`
- Modify: `OndaTests/PlaybackManagerTests.swift`

**Interfaces:**
- Consumes: `BoostLevel`, `SilenceDetector`, `AdWindow`, engine `setBoostGain` / `onRMS`.
- Produces (added to `PlaybackManager`):
  - Applies boost gain on `play` and whenever `ShowSettings.voiceBoost` changes (`func applyAudioSettings()`).
  - On each RMS callback: if `settings.skipSilence`, feed `SilenceDetector`; on a `Skip`, `skip(by: skip.seconds)`.
  - `var adActive: Bool` — recomputed on time updates from an `AdWindow` built from `currentEpisode.chapters`; when `settings.adSkipMode == "auto"` and inside an ad, auto-seek to `adEnd`.
  - `applyAudioSettings()` is called from the Now Playing chips (replaces the direct settings mutation with a settings-mutate-then-apply).

- [ ] **Step 1: Write failing tests (silence-driven skip + ad detection)**

Append to `OndaTests/PlaybackManagerTests.swift`. Extend `makeEpisode` usage by adding chapters in-test:

```swift
extension PlaybackManagerTests {
    func test_skipSilenceSetting_seeksOnDetectedSilence() throws {
        let ctx = try ctx()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 1000)
        ep.podcast?.settings?.skipSilence = true
        pm.play(ep)
        engine.emitTime(100)
        // Feed sustained silence via the engine RMS hook.
        for _ in 0..<10 { engine.onRMS?(0.001, 0.1) }
        XCTAssertGreaterThan(engine.currentTimeSeconds, 100, "a silence skip advanced position")
    }

    func test_adActive_trueInsideAdChapter_whenChaptersPresent() throws {
        let ctx = try ctx()
        let engine = FakeEngine()
        let pm = PlaybackManager(engine: engine, modelContext: ctx)
        let ep = makeEpisode(in: ctx, duration: 2292)
        let c1 = Chapter(title: "Intro", startTime: 0, isAd: false)
        let c2 = Chapter(title: "Sponsor", startTime: 600, isAd: true)
        let c3 = Chapter(title: "Main", startTime: 780, isAd: false)
        [c1, c2, c3].forEach { $0.episode = ep; ep.chapters.append($0); ctx.insert($0) }
        pm.play(ep)
        engine.emitTime(100); XCTAssertFalse(pm.adActive)
        engine.emitTime(650); XCTAssertTrue(pm.adActive)
        engine.emitTime(900); XCTAssertFalse(pm.adActive)
    }
}
```

Add the RMS hook to `FakeEngine` (so tests can push RMS): it already declares `onRMS` from Task 4 Step 2; ensure `play()`/`load()` leave it assignable. No further change needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests/test_adActive_trueInsideAdChapter_whenChaptersPresent`
Expected: FAIL — `value of type 'PlaybackManager' has no member 'adActive'`.

- [ ] **Step 3: Add audio-settings + silence + ad logic to PlaybackManager**

Add properties and methods to `PlaybackManager`:

```swift
    var adActive: Bool = false
    private var silence = SilenceDetector()

    func applyAudioSettings() {
        let boost = BoostLevel(clamping: settings?.voiceBoost ?? 0)
        engine.setBoostGain(boost.gain)
        if settings?.skipSilence != true { silence.reset() }
    }

    private func adWindow(for ep: Episode) -> AdWindow {
        AdWindow(chapters: ep.chapters.map { ($0.startTime, $0.isAd) }, duration: ep.duration)
    }
```

In `init`, after existing engine callback wiring, add the RMS hook:

```swift
        engine.onRMS = { [weak self] rms, secs in
            guard let self, self.settings?.skipSilence == true else { return }
            if let skip = self.silence.consume(rms: rms, bufferSeconds: secs) {
                self.skip(by: skip.seconds)
            }
        }
```

In `play(_:)`, after `engine.rate = ...`, add:
```swift
        applyAudioSettings()
        silence.reset()
```

In `handleTimeUpdate(_:)`, after `positionSeconds = t` and before the outro check, add ad detection + auto-skip:
```swift
        if let ep = currentEpisode, !ep.chapters.isEmpty {
            let w = adWindow(for: ep)
            adActive = w.isAd(at: t)
            if adActive, settings?.adSkipMode == "auto", let end = w.adEnd(at: t), end > t {
                engine.seek(to: end); positionSeconds = end; adActive = false
            }
        } else {
            adActive = false
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/PlaybackManagerTests`
Expected: PASS (all PlaybackManager tests, incl. the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add Onda/Playback/PlaybackManager.swift OndaTests/PlaybackManagerTests.swift
git commit -m "feat: wire voice boost, skip-silence seeking, and ad detection/auto-skip into PlaybackManager"
```

---

### Task 6: Ad banner in Now Playing + chips apply audio settings

**Files:**
- Modify: `Onda/Player/NowPlayingView.swift`

**Interfaces:**
- Consumes: `playback.adActive`, `settings.adSkipMode`, `applyAudioSettings()`.
- Produces: an ad banner shown only when `playback.adActive`; a "Skip Ad" button visible when `adSkipMode == "manual"` that seeks past the ad; Boost/Silence chips now call `applyAudioSettings()` after mutating settings.

- [ ] **Step 1: Add the ad banner and wire chips to applyAudioSettings**

In `NowPlayingView`, add the banner directly under the scrubber (before `transport`):

```swift
                if playback.adActive {
                    HStack {
                        Text(settings?.adSkipMode == "auto" ? "Skipping ad…" : "Ad break in progress")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.color(.text))
                        Spacer()
                        if settings?.adSkipMode == "manual" {
                            Button("Skip Ad") {
                                if let ep, let end = AdWindow(
                                    chapters: ep.chapters.map { ($0.startTime, $0.isAd) },
                                    duration: ep.duration).adEnd(at: playback.positionSeconds) {
                                    playback.seek(toFraction: end / max(1, ep.duration))
                                }
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.color(.accent))
                        }
                    }
                    .padding(12).background(theme.color(.accentWash)).brutalBorder(width: 2)
                    .frame(maxWidth: 280)
                }
```

Change the chip handlers to apply settings after mutating:
```swift
    private func toggleBoost() { settings.map { $0.voiceBoost = ($0.voiceBoost + 1) % 3 }; playback.applyAudioSettings() }
    private func toggleSilence() { settings.map { $0.skipSilence.toggle() }; playback.applyAudioSettings() }
```

- [ ] **Step 2: Build and run — verify boost audibly changes and banner shows on an ad-marked feed**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Manual verification: play an episode; toggle Boost to High → audio is louder; on a feed with an ad-marked chapter (use the `feed_basic.xml` + `chapters.json`-style show, or a real Podcasting-2.0 feed), the banner appears while inside the ad window and (auto mode) playback jumps past it.

- [ ] **Step 3: Commit**

```bash
git add Onda/Player/NowPlayingView.swift
git commit -m "feat: Now Playing ad banner (real ad markers only) + chips apply audio settings"
```

---

## Self-Review

- **Spec coverage:** Voice Boost via `MTAudioProcessingTap` gain ✓; Skip Silence via RMS detection + `AVPlayer` seek ✓ (accepted-coarse, thresholds centralized); ad banner rendered **only** when a real Podcasting-2.0 ad chapter is active ✓; auto/manual ad-skip modes ✓; `AVAudioEngine` explicitly not used ✓; canonical feed-time preserved (all skips go through `seek`) ✓.
- **Placeholder scan:** None. All logic is either implemented here or delegated to the pure types (BoostLevel/SilenceDetector/AdWindow) that are fully implemented and tested.
- **Type consistency:** `BoostLevel(clamping:).gain`, `SilenceDetector.consume(rms:bufferSeconds:) -> Skip?`, `AdWindow(chapters:duration:).isAd(at:)/adEnd(at:)`, `engine.setBoostGain(_:)`, `engine.onRMS`, `playback.adActive`, `applyAudioSettings()` are used identically across tasks and match the `PlayerEngine`/`PlaybackManager` surface from Plan 3.
