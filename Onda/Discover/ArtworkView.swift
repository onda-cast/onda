//  ArtworkView.swift
import SwiftUI

struct ArtworkView: View {
    @Environment(AppTheme.self) private var theme
    let url: URL?
    let seed: String

    private var hue: Double { Double(abs(seed.hashValue) % 360) }

    var body: some View {
        ZStack {
            gradient
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipped()
        .brutalBorder(width: 2.5)
    }

    private var gradient: some View {
        LinearGradient(
            colors: [Color(hue: hue / 360, saturation: 0.35, brightness: theme.resolvedAppearance == .dark ? 0.32 : 0.82),
                     Color(hue: hue / 360, saturation: 0.30, brightness: theme.resolvedAppearance == .dark ? 0.24 : 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
