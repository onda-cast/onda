//  ShowPreviewSheet.swift
//  Lightweight look-before-you-follow: artwork, metadata, and the latest episodes of a
//  Discover result, fetched from its public feed. Follow works from here too.
import SwiftUI

struct ShowPreviewSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    let dto: PodcastDTO
    let isSubscribed: Bool
    var onToggle: () -> Void

    @State private var feed: ParsedFeed?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ArtworkView(url: dto.artworkUrl600, seed: dto.collectionName)
                        .frame(width: 88, height: 88).hardShadow(offset: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dto.collectionName).brutalHeader(size: 16)
                            .foregroundStyle(theme.color(.text)).lineLimit(2)
                        Text(dto.artistName).scaledFont(13)
                            .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
                        Text(dto.primaryGenreName ?? "Podcast").scaledFont(12)
                            .foregroundStyle(theme.color(.textTertiary))
                    }
                    Spacer(minLength: 0)
                }

                Button(action: onToggle) {
                    Text(isSubscribed ? "Following" : "Follow")
                        .scaledFont(14, weight: .bold).textCase(.uppercase)
                        .foregroundStyle(isSubscribed ? theme.color(.textSecondary) : .white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(isSubscribed ? theme.color(.bgElevated) : theme.color(.accentStrong))
                        .brutalBorder(width: 2.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSubscribed ? "Following \(dto.collectionName), tap to unfollow"
                    : "Follow \(dto.collectionName)")

                Text("Latest Episodes").brutalHeader(size: 13)
                    .foregroundStyle(theme.color(.textTertiary))

                if let feed {
                    ForEach(Array(feed.episodes.prefix(8).enumerated()), id: \.offset) { _, ep in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).scaledFont(14, weight: .semibold)
                                .foregroundStyle(theme.color(.text)).lineLimit(2)
                            Text(ep.publishDate.formatted(.relative(presentation: .named)))
                                .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }
                } else if failed {
                    BrutalEmptyState("Couldn\u{2019}t load this show\u{2019}s feed",
                                     detail: "You can still follow it \u{2014} episodes load after subscribing.")
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(theme.color(.accent))
                        Text("Loading episodes\u{2026}").scaledFont(13)
                            .foregroundStyle(theme.color(.textTertiary))
                    }.frame(maxWidth: .infinity).padding(.top, 12)
                }
            }
            .padding(20)
        }
        .background(theme.color(.bg))
        .task {
            guard let url = dto.feedUrl else { failed = true; return }
            do { feed = try await subscriptions.previewFeed(url) } catch { failed = true }
        }
    }
}
