//  ArtworkView.swift
import SwiftUI

struct ArtworkView: View {
    @Environment(AppTheme.self) private var theme
    let url: URL?
    let seed: String

    private var hue: Double { Double(abs(seed.hashValue) % 360) }
    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            gradient
            // Cache hit renders synchronously — AsyncImage restarted from its empty phase on
            // every tab-switch rebuild, flashing placeholders across the whole grid.
            if let url, let image = ArtworkCache.shared.image(for: url) ?? loaded {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .brutalBorder(width: 2.5)
        .task(id: url) {
            guard let url, ArtworkCache.shared.image(for: url) == nil else { return }
            loaded = await ArtworkCache.shared.load(url)
        }
    }

    private var gradient: some View {
        LinearGradient(
            colors: [Color(hue: hue / 360, saturation: 0.35, brightness: theme.resolvedAppearance == .dark ? 0.32 : 0.82),
                     Color(hue: hue / 360, saturation: 0.30, brightness: theme.resolvedAppearance == .dark ? 0.24 : 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
