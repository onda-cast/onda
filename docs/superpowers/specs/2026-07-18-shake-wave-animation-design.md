# Shake Wave Animation — Design

**Date:** 2026-07-18
**Feature:** A big blue wave washes across the Discover screen when the user shakes to shuffle
(or taps the Shuffle button).

## Goal

Give shake-to-discover a signature, on-brand moment. *Onda* means "wave" — when a shake
registers, a wave sweeps across the whole screen as immediate feedback, masking the network
round-trip before the new picks deal in.

## Behavior

- **Trigger:** the wave plays the moment `triggerShake()` runs (device shake or Shuffle
  button) — i.e. on every increment of `shakeCount` in `DiscoverView`. It does not wait for
  results.
- **Motion:** the wave enters from off-screen left and sweeps horizontally across the full
  screen, exiting off the right edge. Total duration ~1.0s.
- **It replaces the dice-cup wobble.** The existing `phaseAnimator` rotation on the Discover
  scroll view is removed. The `.sensoryFeedback(.impact…, trigger: shakeCount)` haptic stays.
- **Non-blocking:** the wave is a pure overlay with `allowsHitTesting(false)`. Search, scroll,
  and the result list keep working underneath. The `DealtCard` staggered deal-in of results is
  unchanged and plays whenever results land (typically as/after the wave passes).
- **Repeat shakes:** a shake during an in-flight wave restarts the sweep (trigger-value change
  restarts the animation); no queueing.
- **Reduce Motion:** with `accessibilityReduceMotion` on, the wave is skipped entirely —
  haptics remain the only shake feedback.

## Visual design

Neo-brutalist "woodblock print" wave — flat fills, hard edges, no gradients or blur:

- **3 layered bands**, each a solid blue mass whose leading (right) edge is a sine-scalloped
  crest profile. Bands are slightly taller than the screen so crests bob above the top edge.
- **Depth by stagger:** lightest blue (foam) leads; mid blue follows ~80ms behind; deep navy
  trails ~160ms behind. Later bands sit visually behind earlier ones.
- **Brutalist detailing:** each band's crest edge is stroked with the theme `border` token at
  ~3pt, and each band casts a hard offset shadow using the theme `cardShadow` token (same
  language as `brutalBorder`/`hardShadow`).
- **Blues** (decorative one-offs, local to the component — deliberately *not* added to
  `ColorToken`):
  - Light mode: foam `#A9D6E5`, mid `#2E7FB8`, deep `#13496F`
  - Dark mode: slightly desaturated variants (approx. foam `#7FB3C8`, mid `#2A6E9E`,
    deep `#0F3A57`) so the wave doesn't glow against the `#111111` background.
  - Exact values may be nudged during visual verification; the constraint is a
    light→mid→deep series that reads in both appearances.

## Architecture

One new file, one edited file.

**New: `Onda/Discover/ShakeWaveOverlay.swift`**

- `WaveBandShape: Shape` — a solid body filling the shape's bounds with a sine-scalloped
  crest as its leading edge. Static geometry (amplitude, wavelength, phase per band); the
  *sweep* is done by animating `offset(x:)`, not by animating the shape, which keeps it cheap.
- `ShakeWaveOverlay: View` — takes `trigger: Int` (the parent's `shakeCount`). On trigger
  change it animates each band's horizontal offset from `-1.3 × width` to `+1.3 × width`
  with `easeInOut` and per-band delay, then resets state for the next run. Reads
  `@Environment(\.accessibilityReduceMotion)` and renders nothing when it's on. Reads
  `AppTheme` for border/shadow tokens and appearance-appropriate blues.

**Edit: `Onda/Shell/DiscoverView.swift`**

- Remove the `.phaseAnimator` dice-cup wobble block.
- Add `.overlay { ShakeWaveOverlay(trigger: shakeCount) }` (full-screen,
  `.allowsHitTesting(false)`, `.ignoresSafeArea()`).

No model, service, or data-flow changes. No new dependencies.

## Error handling

None needed — the animation is fire-and-forget and independent of the network fetch. If the
shake fetch returns nothing, behavior is as today (list stays on Trending); the wave has
already played, which is acceptable feedback for "we tried".

## Testing

Visual-only feature with no branching logic worth unit-testing. Verification is end-to-end in
the simulator via the project `verify` skill: build, open Discover, tap Shuffle, confirm the
wave sweeps correctly in light and dark mode, confirm taps register during the sweep, and
confirm Reduce Motion suppresses it. Existing test suite must stay green (no behavior it
covers is touched beyond removing the wobble).
