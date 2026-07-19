//  MiniPlayerAutoHide.swift
import SwiftUI

/// Content-focused browsing: scrolling down a surface tucks the mini-player away
/// (`PlaybackManager.miniPlayerHidden`); a sustained upward scroll or nearing the top brings it
/// back. Scroll events arrive per FRAME (tiny deltas), so hide/reveal use cumulative directional
/// runs — ~60pt of downward travel hides, ~80pt of upward travel reveals (a threshold the bottom
/// rubber-band bounce rarely reaches). Leaving the surface always restores the bar; so do tab
/// switches and starting playback (handled in RootView/PlaybackManager).
///
/// Uses the iOS 18 scroll-geometry API; on iOS 17 the modifier is a no-op (bar never hides).
struct MiniPlayerAutoHide: ViewModifier {
    let playback: PlaybackManager
    @State private var lastY: CGFloat = 0
    @State private var upwardRun: CGFloat = 0
    @State private var downwardRun: CGFloat = 0

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18.0, *) {
                content.onScrollGeometryChange(for: CGFloat.self,
                                               of: { $0.contentOffset.y + $0.contentInsets.top },
                                               action: { _, new in handleScroll(offsetY: new) })
            } else {
                content
            }
        }
        .onDisappear { playback.miniPlayerHidden = false }
    }

    // offsetY is 0 at the top and grows as the user scrolls down into content.
    private func handleScroll(offsetY: CGFloat) {
        defer { lastY = offsetY }
        let delta = offsetY - lastY
        if delta > 0 {
            downwardRun += delta; upwardRun = 0
        } else if delta < 0 {
            upwardRun -= delta; downwardRun = 0
        }
        if offsetY <= 30 || upwardRun > 80 {
            if playback.miniPlayerHidden { playback.miniPlayerHidden = false }
        } else if downwardRun > 60 {
            if !playback.miniPlayerHidden { playback.miniPlayerHidden = true }
        }
    }
}

extension View {
    /// Hides the mini-player while this scrollable surface is scrolled down; see ``MiniPlayerAutoHide``.
    func miniPlayerAutoHide(_ playback: PlaybackManager) -> some View {
        modifier(MiniPlayerAutoHide(playback: playback))
    }
}
