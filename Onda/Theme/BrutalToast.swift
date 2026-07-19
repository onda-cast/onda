//  BrutalToast.swift
import SwiftUI

/// The single toast appearance for every surface (RootView's app-wide toasts, Library's and
/// Discover's local ones) — extracted because three hand-rolled copies had drifted in color,
/// size, and shadow. Callers own positioning (bottom padding) and show/hide animation.
///
/// Also the one place toasts are announced to VoiceOver: they're transient visual overlays that
/// are otherwise silent to screen readers.
struct BrutalToast: View {
    @Environment(AppTheme.self) private var theme
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(13.5, weight: .semibold).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(theme.color(.accentStrong)).brutalBorder(width: 2).hardShadow(offset: 3)
            .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}
