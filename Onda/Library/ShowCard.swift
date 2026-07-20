//  ShowCard.swift
import SwiftUI

struct ShowCard: View {
    @Environment(AppTheme.self) private var theme
    let podcast: Podcast
    // Unplayed AND downloaded episode count, from the cached LibrarySortKeys pass — never
    // computed inline here (that's the exact per-render episode-relationship fault
    // LatestEpisodeSubtitle was built to avoid).
    var unplayedCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(url: podcast.artworkURL, seed: podcast.title, cached: true)
                .aspectRatio(1, contentMode: .fit)
                .hardShadow(offset: 4)
                .overlay(alignment: .topTrailing) { unplayedBadge }
            HStack(spacing: 6) {
                Text(podcast.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(2)
                if podcast.isPrivateFeed {
                    Text("PRIVATE").scaledFont(9, weight: .heavy)
                        .foregroundStyle(theme.color(.bg))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.color(.textSecondary))
                        .accessibilityLabel("Private feed")
                }
            }
            LatestEpisodeSubtitle(podcast: podcast)
        }
    }

    @ViewBuilder private var unplayedBadge: some View {
        if unplayedCount > 0 {
            Text(unplayedCount > 99 ? "99+" : "\(unplayedCount)")
                .scaledFont(11, weight: .black)
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(minWidth: 22, minHeight: 22)
                .background(theme.color(.accentStrong))
                .brutalBorder(width: 2)
                .offset(x: 8, y: -8)
                .accessibilityLabel("\(unplayedCount) new downloaded episode\(unplayedCount == 1 ? "" : "s")")
        }
    }
}
