# Shake Wave Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A hard-edged, 3-band blue wave sweeps left→right across the Discover screen the moment shake-to-shuffle triggers, replacing the dice-cup wobble.

**Architecture:** One new self-contained overlay view (`ShakeWaveOverlay`) driven by the existing `shakeCount` trigger in `DiscoverView`. Each band is a static `Shape` with a sine-scalloped leading edge; the sweep animates `offset(x:)` only. No model/service changes.

**Tech Stack:** SwiftUI (iOS 17+), XcodeGen, existing `Theme/` brutalist tokens.

**Spec:** `docs/superpowers/specs/2026-07-18-shake-wave-animation-design.md`

## Global Constraints

- Neo-brutalist visual language: flat fills, no gradients/blur; borders use `theme.color(.border)`, shadows use `theme.color(.cardShadow)` (spec "Visual design").
- Wave blues are local to the component — do NOT add tokens to `ColorToken` (spec "Visual design").
- Light blues: foam `A9D6E5`, mid `2E7FB8`, deep `13496F`; dark: foam `7FB3C8`, mid `2A6E9E`, deep `0F3A57` (nudging during visual verification is allowed).
- Overlay must be `allowsHitTesting(false)` and skipped entirely under `accessibilityReduceMotion` (spec "Behavior").
- The `.sensoryFeedback(.impact(weight: .medium), trigger: shakeCount)` haptic and the `DealtCard` deal-in stay unchanged.
- The project is XcodeGen-generated: after creating a new file, run `xcodegen generate` before building.
- This feature is visual-only; the spec's test strategy is simulator verification (project `verify` skill), not unit tests. Each task's gate is a clean build (plus, at the end, the existing test suite staying green).

---

### Task 1: `ShakeWaveOverlay` component

**Files:**
- Create: `Onda/Discover/ShakeWaveOverlay.swift`

**Interfaces:**
- Consumes: `AppTheme` from the environment (`theme.color(.border)`, `theme.color(.cardShadow)`, `theme.resolvedAppearance` — check `Onda/Theme/Theme.swift` for the exact name of the resolved light/dark property before using it; if the theme exposes only a scheme-agnostic API, use `@Environment(\.colorScheme)` instead to pick the light/dark blue set).
- Produces: `ShakeWaveOverlay(trigger: Int)` — a full-screen decorative view. Incrementing `trigger` plays one left→right sweep (~1s). Renders nothing when Reduce Motion is on. Task 2 relies on exactly this initializer.

- [ ] **Step 1: Create the file**

```swift
//  ShakeWaveOverlay.swift
//  A neo-brutalist "woodblock print" wave that washes left→right across the screen when
//  shake-to-shuffle triggers: three flat blue bands with sine-scalloped crests, each outlined
//  and hard-shadowed with the theme's border/shadow tokens. Pure decoration — never blocks
//  touches, and disappears entirely under Reduce Motion.
import SwiftUI

/// A solid band filling the rect, whose trailing (right) edge — the leading edge of the
/// left→right sweep — is a sine-scalloped crest. Geometry is static; the sweep animates
/// `offset(x:)` in the parent, which keeps the shape cheap to render.
struct WaveBandShape: Shape {
    var amplitude: CGFloat
    var wavelength: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let crestX = rect.maxX - amplitude
        func x(at y: CGFloat) -> CGFloat {
            crestX + sin(phase + y / wavelength * 2 * .pi) * amplitude
        }
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: x(at: rect.minY), y: rect.minY))
        let steps = max(2, Int(rect.height / 4))
        for i in 1...steps {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(steps)
            p.addLine(to: CGPoint(x: x(at: y), y: y))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct ShakeWaveOverlay: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Increment to play one sweep. A change mid-sweep restarts from the left.
    let trigger: Int

    // One entry per band; progress 0 = parked off-screen left, 1 = exited off-screen right.
    @State private var progress: [CGFloat] = [0, 0, 0]

    private struct Band {
        let lightHex: String
        let darkHex: String
        let delay: Double
        let amplitude: CGFloat
        let wavelength: CGFloat
        let phase: CGFloat
    }

    // Foam leads, mid follows, deep navy trails — depth by stagger (spec "Visual design").
    private static let bands: [Band] = [
        Band(lightHex: "A9D6E5", darkHex: "7FB3C8", delay: 0.00, amplitude: 30, wavelength: 150, phase: 0.0),
        Band(lightHex: "2E7FB8", darkHex: "2A6E9E", delay: 0.08, amplitude: 26, wavelength: 120, phase: 1.7),
        Band(lightHex: "13496F", darkHex: "0F3A57", delay: 0.16, amplitude: 22, wavelength: 100, phase: 3.4),
    ]

    var body: some View {
        if !reduceMotion {
            GeometryReader { geo in
                // Draw deep-navy first so the lighter, earlier bands overlap in front of it.
                ZStack {
                    ForEach(Array(Self.bands.enumerated().reversed()), id: \.offset) { i, band in
                        bandView(band, size: geo.size)
                            // Band is 1.4× screen width; travel from fully off left to fully
                            // off right so nothing is visible at progress 0 or 1.
                            .offset(x: -1.5 * geo.size.width + progress[i] * 3.0 * geo.size.width)
                    }
                }
            }
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in sweep() }
        }
    }

    private func bandView(_ band: Band, size: CGSize) -> some View {
        let shape = WaveBandShape(amplitude: band.amplitude,
                                  wavelength: band.wavelength,
                                  phase: band.phase)
        let fill = Color(hex: colorScheme == .dark ? band.darkHex : band.lightHex)
        return ZStack {
            shape.fill(theme.color(.cardShadow)).offset(x: 5, y: 5)   // hard shadow
            shape.fill(fill)
            shape.stroke(theme.color(.border), lineWidth: 3)
        }
        // Taller than the screen so the crest bobs above the top edge (spec "Visual design").
        .frame(width: 1.4 * size.width, height: size.height + 60)
        .offset(y: -30)
    }

    private func sweep() {
        // Instant reset (no withAnimation) so a shake mid-sweep restarts from the left.
        for i in Self.bands.indices { progress[i] = 0 }
        // Defer the animated set one runloop turn: if reset and animation land in the same
        // update, SwiftUI animates from the last *rendered* value (1 → 1 = no sweep at all).
        Task { @MainActor in
            for i in Self.bands.indices {
                withAnimation(.easeInOut(duration: 0.85).delay(Self.bands[i].delay)) {
                    progress[i] = 1
                }
            }
        }
    }
}
```

- [ ] **Step 2: Check the theme's appearance API**

Run: `grep -n "colorScheme\|resolvedAppearance\|appearance" Onda/Theme/Theme.swift`

The code above uses `@Environment(\.colorScheme)` to pick light/dark blues. If `AppTheme` resolves appearance itself (the app supports a forced light/dark setting via `Appearance.system/.light/.dark`), the environment `colorScheme` may not match the forced theme. If `Theme.swift` exposes a resolved appearance (e.g. an `Appearance`-returning property used by `theme.color(_:)`), switch the fill line to use it:

```swift
// only if AppTheme exposes resolved appearance; otherwise keep colorScheme
let fill = Color(hex: theme.resolvedIsDark ? band.darkHex : band.lightHex)
```

Match whatever mechanism `theme.color(_:)` itself uses so wave blues flip together with the rest of the palette.

- [ ] **Step 3: Regenerate the project and build**

```sh
xcodegen generate
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `BUILD SUCCEEDED` (warnings at most; the new file compiles even though nothing uses it yet).

- [ ] **Step 4: Lint**

Run: `swiftlint lint --path Onda/Discover/ShakeWaveOverlay.swift` (or plain `swiftlint lint` if `--path` is unsupported in the installed version)
Expected: no violations in the new file.

- [ ] **Step 5: Commit**

```bash
git add Onda/Discover/ShakeWaveOverlay.swift Onda.xcodeproj
git commit -m "Add ShakeWaveOverlay: brutalist 3-band blue wave sweep"
```

---

### Task 2: Wire the wave into DiscoverView, remove the wobble

**Files:**
- Modify: `Onda/Shell/DiscoverView.swift` (the `.phaseAnimator` block around lines 176–180, and the modifier chain on the `ScrollView` in `body`)

**Interfaces:**
- Consumes: `ShakeWaveOverlay(trigger: Int)` from Task 1; existing `shakeCount: Int` state.
- Produces: final user-facing behavior; nothing downstream.

- [ ] **Step 1: Remove the dice-cup wobble**

Delete these lines from `body`'s modifier chain (including the comment):

```swift
        // Dice-cup wobble the moment a shake registers — feedback that the roll is happening,
        // before the network round-trip lands the results.
        .phaseAnimator([0, -1.6, 1.9, -1.2, 0.8, 0], trigger: shakeCount) { view, angle in
            view.rotationEffect(.degrees(angle), anchor: .center)
        } animation: { _ in .spring(duration: 0.07, bounce: 0.5) }
```

- [ ] **Step 2: Add the wave overlay**

In the same modifier chain, immediately after `.refreshable { await pullRefresh() }` (where the wobble was), add:

```swift
        // The Onda wave — washes across the screen the moment a shake registers, feedback
        // that the roll is happening before the network round-trip lands the results.
        .overlay {
            ShakeWaveOverlay(trigger: shakeCount)
                .ignoresSafeArea()
        }
```

(`ShakeWaveOverlay` already sets `allowsHitTesting(false)` internally.)

- [ ] **Step 3: Build**

```sh
xcodebuild build -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Onda/Shell/DiscoverView.swift
git commit -m "Discover: wave wash on shake-to-shuffle (replaces dice-cup wobble)"
```

---

### Task 3: End-to-end verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: the built app from Tasks 1–2.
- Produces: verified feature; evidence for completion claims.

- [ ] **Step 1: Run the existing test suite**

```sh
xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: all existing tests pass (the wobble removal touches no tested behavior).

- [ ] **Step 2: Verify in the simulator with the project `verify` skill**

Use the `verify` skill (build, launch, drive the app). Check, capturing screenshots mid-sweep where possible:

1. Discover tab → tap SHUFFLE: a 3-band blue wave sweeps left→right in ~1s; lightest band leads, deep navy trails; crests are outlined with hard shadows.
2. During the sweep, the screen stays interactive (tap a category chip mid-wave; it registers).
3. New picks still deal in with the `DealtCard` stagger after the wave.
4. Toggle dark mode (or the app's theme setting): wave uses the darker desaturated blues and white borders.
5. Tap SHUFFLE twice quickly: the sweep restarts cleanly from the left, no stuck bands.
6. Nudge blues/amplitudes only if something looks off on-screen (allowed by spec).

Reduce Motion (simulator: Settings → Accessibility → Motion → Reduce Motion, or
`xcrun simctl spawn booted defaults write com.apple.Accessibility ReduceMotionEnabled -bool true` then relaunch the app): shuffle produces no wave, list still updates.

- [ ] **Step 3: Final commit (only if verification forced tweaks)**

```bash
git add -A && git commit -m "Tune wave colors/geometry after simulator verification"
```
