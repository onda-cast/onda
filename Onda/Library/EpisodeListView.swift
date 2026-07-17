//  EpisodeListView.swift
import SwiftUI
import SwiftData

@MainActor
struct EpisodeListView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(PlaybackManager.self) private var playback
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast
    @State private var showSettings = false
    @State private var filter: EpisodeFilter = .downloaded

    private var episodes: [Episode] {
        filter.apply(to: podcast.episodes)
    }

    // List (not ScrollView) so rows get native HIG swipe actions; context menu stays as
    // the redundant secondary access per Apple's guidance.
    var body: some View {
        List {
            Group {
                header
                SegmentedRow(options: EpisodeFilter.allCases.map { ($0.label, $0) },
                             selection: filter) { filter = $0 }
                if episodes.isEmpty && filter == .downloaded {
                    Text("No downloaded episodes — switch to All or Newest 10")
                        .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .listRowBackground(theme.color(.bg))
            .listRowSeparator(.hidden)

            ForEach(episodes) { ep in
                EpisodeRow(episode: ep,
                           downloadState: downloads.state(for: ep),
                           onPlay: { playback.play(ep) },
                           onDownload: {
                               switch downloads.state(for: ep) {
                               case .downloaded: downloads.delete(ep)
                               case .failed:     downloads.retryManually(guid: ep.guid)
                               case .downloading: break
                               case .none:       downloads.download(ep)
                               }
                           })
                .listRowBackground(theme.color(.bg))
                .listRowSeparatorTint(theme.color(.separator))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        subscriptions.setPlayed(ep, !ep.played)
                    } label: {
                        Label(ep.played ? "UNPLAYED" : "PLAYED",
                              systemImage: ep.played ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(theme.color(.accent))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Flat black over system red: matches the brutal palette. Trash icon +
                    // placement keep the destructive meaning unambiguous.
                    Button { deleteEpisode(ep) } label: {
                        Label("DELETE", systemImage: "trash.fill")
                    }
                    .tint(.black)
                }
                .contextMenu {
                    Button {
                        subscriptions.setPlayed(ep, !ep.played)
                    } label: {
                        Label(ep.played ? "Mark as Unplayed" : "Mark as Played",
                              systemImage: ep.played ? "circle" : "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        deleteEpisode(ep)
                    } label: {
                        Label("Delete Episode", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.color(.bg))
        .refreshable { await refresh() }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { ShowSettingsSheet(podcast: podcast) }
    }

    private func deleteEpisode(_ ep: Episode) {
        downloads.delete(ep)   // audio file + download record
        subscriptions.archiveEpisode(ep, keepTranscript: appSettings.keepTranscriptsOnDelete)
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
