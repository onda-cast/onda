//  EpisodeListView.swift
import SwiftUI
import SwiftData

@MainActor
struct EpisodeListView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast

    private var episodes: [Episode] {
        podcast.episodes.sorted { $0.publishDate > $1.publishDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().overlay(theme.color(.separator))
                ForEach(episodes) { ep in
                    EpisodeRow(episode: ep)
                    Divider().overlay(theme.color(.separator))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .background(theme.color(.bg))
        .refreshable { await refresh() }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() async {
        try? await subscriptions.refreshEpisodes(for: podcast)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: podcast.artworkURL, seed: podcast.title)
                .frame(width: 96, height: 96).hardShadow(offset: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(podcast.title).brutalHeader(size: 20).foregroundStyle(theme.color(.text))
                Text(podcast.category).font(.system(size: 13))
                    .foregroundStyle(theme.color(.textTertiary))
                Button("Unsubscribe") {
                    subscriptions.unsubscribe(podcast); dismiss()
                }
                .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.color(.accent))
            }
            Spacer()
        }
        .padding(.top, 12)
    }
}
