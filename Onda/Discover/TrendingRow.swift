//  TrendingRow.swift
import SwiftUI

struct TrendingRow: View {
    @Environment(AppTheme.self) private var theme
    let dto: PodcastDTO
    let isSubscribed: Bool
    // Follow when not subscribed; tap again to unfollow (parent confirms).
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: dto.artworkUrl600, seed: dto.collectionName)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(dto.collectionName).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(1)
                Text(dto.primaryGenreName ?? "Podcast").scaledFont(13)
                    .foregroundStyle(theme.color(.textTertiary))
            }
            Spacer(minLength: 8)
            Button(action: onToggle) {
                Text(isSubscribed ? "Following" : "Follow")
                    .scaledFont(13, weight: .bold).textCase(.uppercase)
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(isSubscribed ? theme.color(.textSecondary) : .white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(isSubscribed ? theme.color(.bg) : theme.color(.accent))
                    .brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            // Rows using .swipeToHide layer a DragGesture over this whole row; a plain-tap
            // Button already wins that arbitration in the common case, but this guarantees
            // it — a stray bit of horizontal finger movement mid-tap must never get eaten by
            // the ancestor's drag instead of toggling Follow.
            .highPriorityGesture(TapGesture().onEnded(onToggle))
            .accessibilityLabel(isSubscribed ? "Following \(dto.collectionName), tap to unfollow"
                                             : "Follow \(dto.collectionName)")
        }
        .padding(10)
        .background(theme.color(.bgElevated))
        .brutalBorder(width: 2)
        .hardShadow(offset: 3)
    }
}
