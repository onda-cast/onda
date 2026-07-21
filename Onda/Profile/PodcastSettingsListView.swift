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

    // Brutalist cards on the theme background — this screen was the last stock grouped List.
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if shows.isEmpty {
                    BrutalEmptyState("No subscribed shows",
                                     detail: "Follow shows in Discover to set per-show overrides.")
                }
                ForEach(shows) { show in
                    Button { selected = show } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: show.artworkURL, seed: show.title, cached: true)
                                .frame(width: 44, height: 44).brutalBorder(width: 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(show.title).scaledFont(15, weight: .semibold)
                                    .foregroundStyle(theme.color(.text)).lineLimit(1)
                                Text(hasOverrides(show) ? "Customized" : "Using defaults")
                                    .scaledFont(12)
                                    .foregroundStyle(hasOverrides(show) ? theme.color(.accent)
                                        : theme.color(.textTertiary))
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this show's settings")
                }
            }
            .padding(20).padding(.bottom, BottomChrome.clearance)
        }
        .background(theme.color(.bg))
        .navigationTitle("Podcast Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { ShowSettingsSheet(podcast: $0) }
    }

    private func hasOverrides(_ show: Podcast) -> Bool {
        guard let s = show.settings else { return false }
        // Every per-show override — playback AND retention. A show with a custom speed
        // must not claim "Using defaults".
        return s.maxDownloadsKeptOverride != nil || s.autoDeleteListenedAfterDaysOverride != nil
            || s.autoTranscribeOnDownloadOverride != nil || s.keepTranscriptsOverride != nil
            || s.speed != nil || s.voiceBoost != nil || s.skipSilence != nil
            || s.adSkipMode != nil || s.autoDownload != nil
            || s.introTrimSec != 0 || s.outroTrimSec != 0
    }
}
