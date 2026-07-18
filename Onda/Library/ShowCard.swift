//  ShowCard.swift
import SwiftUI

struct ShowCard: View {
    @Environment(AppTheme.self) private var theme
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(url: podcast.artworkURL, seed: podcast.title)
                .aspectRatio(1, contentMode: .fit)
                .hardShadow(offset: 4)
            HStack(spacing: 6) {
                Text(podcast.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(2)
                if podcast.isPrivateFeed {
                    Text("PRIVATE").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(theme.color(.bg))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.color(.textSecondary))
                        .accessibilityLabel("Private feed")
                }
            }
            Text(podcast.episodes.first?.title ?? "No episodes")
                .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
                .lineLimit(1)
        }
    }
}
