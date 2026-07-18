//  PodcastSettingsListView.swift
//  Second entry point into per-show settings: general settings → Podcasts → a show opens the
//  same ShowSettingsSheet used from the episode list and Now Playing.
import SwiftUI
import SwiftData

struct PodcastSettingsListView: View {
    @Environment(AppTheme.self) private var theme
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]
    @State private var selected: Podcast?

    var body: some View {
        List {
            if shows.isEmpty {
                Text("No subscribed shows").foregroundStyle(theme.color(.textTertiary))
            }
            ForEach(shows) { show in
                Button { selected = show } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: show.artworkURL, seed: show.title)
                            .frame(width: 40, height: 40).clipped()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.title).scaledFont(15, weight: .semibold)
                                .foregroundStyle(theme.color(.text)).lineLimit(1)
                            Text(hasOverrides(show) ? "Customized" : "Using defaults")
                                .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                    }
                }
            }
        }
        .navigationTitle("Podcast Settings")
        .sheet(item: $selected) { ShowSettingsSheet(podcast: $0) }
    }

    private func hasOverrides(_ show: Podcast) -> Bool {
        guard let s = show.settings else { return false }
        return s.maxDownloadsKeptOverride != nil || s.autoDeleteListenedAfterDaysOverride != nil
            || s.autoTranscribeOnDownloadOverride != nil || s.keepTranscriptsOverride != nil
    }
}
