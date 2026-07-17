//  TrendingRow.swift
import SwiftUI

struct TrendingRow: View {
    @Environment(AppTheme.self) private var theme
    let dto: PodcastDTO
    let isSubscribed: Bool
    var onFollow: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: dto.artworkUrl600, seed: dto.collectionName)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(dto.collectionName).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(1)
                Text(dto.primaryGenreName ?? "Podcast").font(.system(size: 13))
                    .foregroundStyle(theme.color(.textTertiary))
            }
            Spacer(minLength: 8)
            Button(action: onFollow) {
                Text(isSubscribed ? "Following" : "Follow")
                    .font(.system(size: 13, weight: .bold)).textCase(.uppercase)
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(isSubscribed ? theme.color(.textTertiary) : theme.color(.accent))
                    .brutalBorder(width: 2)
            }.buttonStyle(.plain).disabled(isSubscribed)
        }
        .padding(10)
        .background(theme.color(.bgElevated))
        .brutalBorder(width: 2)
        .hardShadow(offset: 3)
    }
}
