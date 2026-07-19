//  ShakeWaveOverlay.swift
//  A neo-brutalist "woodblock print" wave that washes left→right across the screen when
//  shake-to-shuffle triggers: three flat blue bands with sine-scalloped crests, each outlined
//  and hard-shadowed with the theme's border/shadow tokens. Pure decoration — never blocks
//  touches, and disappears entirely under Reduce Motion.
import SwiftUI

/// A solid band whose right edge (the crest leading the left→right sweep) and left edge (the
/// tail that exits last) are both sine-scalloped, phase-shifted so they don't mirror each
/// other. Geometry is static; the sweep animates `offset(x:)` in the parent, which keeps the
/// shape cheap to render.
struct WaveBandShape: Shape {
    var amplitude: CGFloat
    var wavelength: CGFloat
    var phase: CGFloat

    // Animating `phase` rolls the scallops along the edges while the band sweeps.
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let leadX = rect.maxX - amplitude
        let trailX = rect.minX + amplitude
        func lead(at y: CGFloat) -> CGFloat {
            leadX + sin(phase + y / wavelength * 2 * .pi) * amplitude
        }
        func trail(at y: CGFloat) -> CGFloat {
            trailX + sin(phase + 2.3 + y / (wavelength * 1.15) * 2 * .pi) * amplitude
        }
        // ~16pt sampling is indistinguishable for wavelengths ≥100 and cuts per-frame path
        // cost ~4× — this path is rebuilt every frame while the phase animates.
        let steps = max(2, Int(rect.height / 16))
        func y(_ i: Int) -> CGFloat { rect.minY + rect.height * CGFloat(i) / CGFloat(steps) }
        p.move(to: CGPoint(x: trail(at: rect.minY), y: rect.minY))
        p.addLine(to: CGPoint(x: lead(at: rect.minY), y: rect.minY))
        for i in 1...steps {
            p.addLine(to: CGPoint(x: lead(at: y(i)), y: y(i)))
        }
        for i in stride(from: steps, through: 0, by: -1) {
            p.addLine(to: CGPoint(x: trail(at: y(i)), y: y(i)))
        }
        p.closeSubpath()
        return p
    }
}

struct ShakeWaveOverlay: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Increment to play one sweep. A change mid-sweep restarts from the left.
    let trigger: Int

    // One entry per band; progress 0 = parked off-screen left, 1 = exited off-screen right.
    @State private var progress: [CGFloat] = [0, 0, 0]
    // Extra phase added to each band's sine edges; animating it makes the scallops undulate.
    @State private var undulation: [CGFloat] = [0, 0, 0]

    private struct Band {
        let lightHex: String
        let darkHex: String
        let delay: Double
        let amplitude: CGFloat
        let wavelength: CGFloat
        let phase: CGFloat
    }

    // Foam leads, mid follows, deep navy trails — depth by stagger.
    private static let bands: [Band] = [
        Band(lightHex: "A9D6E5", darkHex: "7FB3C8", delay: 0.00, amplitude: 30, wavelength: 150, phase: 0.0),
        Band(lightHex: "2E7FB8", darkHex: "2A6E9E", delay: 0.08, amplitude: 26, wavelength: 120, phase: 1.7),
        Band(lightHex: "13496F", darkHex: "0F3A57", delay: 0.16, amplitude: 22, wavelength: 100, phase: 3.4)
    ]

    var body: some View {
        if !reduceMotion {
            GeometryReader { geo in
                // Draw deep-navy first so the lighter, earlier bands overlap in front of it.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(Self.bands.enumerated().reversed()), id: \.offset) { i, band in
                        bandView(band, index: i, size: geo.size)
                            // Band is 1.4× screen width; travel from fully off left to fully
                            // off right so nothing is visible at progress 0 or 1.
                            .offset(x: -1.5 * geo.size.width + progress[i] * 3.0 * geo.size.width)
                    }
                }
                // Rasterize the whole wave offscreen via Metal — three animating multi-layer
                // paths are too much for per-frame CPU compositing on older phones.
                .drawingGroup()
            }
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in sweep() }
        }
    }

    private func bandView(_ band: Band, index: Int, size: CGSize) -> some View {
        let shape = WaveBandShape(amplitude: band.amplitude,
                                  wavelength: band.wavelength,
                                  phase: band.phase + undulation[index])
        let isDark = theme.resolvedAppearance == .dark
        let fill = Color(hex: isDark ? band.darkHex : band.lightHex)
        return ZStack {
            shape.fill(theme.color(.cardShadow)).offset(x: 5, y: 5)   // hard shadow
            shape.fill(fill)
            shape.stroke(theme.color(.border), lineWidth: 3)
        }
        // Taller than the screen so the crest bobs above the top edge.
        .frame(width: 1.4 * size.width, height: size.height + 60)
        .offset(y: -30)
    }

    private func sweep() {
        // Instant reset (no withAnimation) so a shake mid-sweep restarts from the left.
        for i in Self.bands.indices {
            progress[i] = 0
            undulation[i] = 0
        }
        // Defer the animated set one runloop turn: if reset and animation land in the same
        // update, SwiftUI animates from the last *rendered* value (1 → 1 = no sweep at all).
        Task { @MainActor in
            for i in Self.bands.indices {
                withAnimation(.easeInOut(duration: 0.85).delay(Self.bands[i].delay)) {
                    progress[i] = 1
                }
                // Linear so the scallops roll at a constant rate for the whole sweep.
                withAnimation(.linear(duration: 0.85).delay(Self.bands[i].delay)) {
                    undulation[i] = 3 * .pi
                }
            }
        }
    }
}
