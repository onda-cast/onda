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
    @Environment(SearchIndexBox.self) private var searchIndexBox
    @Environment(ArticleConversionService.self) private var articles
    @Environment(\.dismiss) private var dismiss
    let podcast: Podcast
    @State private var showSettings = false
    @State private var showTranscripts = false
    @State private var filter: EpisodeFilter = .downloaded
    @State private var query = ""
    @State private var results: [EpisodeSearchResult] = []

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var episodes: [Episode] {
        filter.apply(to: podcast.episodes)
    }

    private var displayedEpisodes: [Episode] {
        isSearching ? results.map(\.episode) : episodes
    }

    private func snippet(for ep: Episode) -> String? {
        results.first { $0.episode.guid == ep.guid }?.snippet
    }

    // List (not ScrollView) so rows get native HIG swipe actions; context menu stays as
    // the redundant secondary access per Apple's guidance.
    var body: some View {
        List {
            Group {
                header
                searchBar
                if !isSearching {
                    SegmentedRow(options: EpisodeFilter.allCases.map { ($0.label, $0) },
                                 selection: filter) { filter = $0 }
                }
                if !isSearching && episodes.isEmpty && filter == .downloaded {
                    Text("No downloaded episodes — switch to All or Newest 10")
                        .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
                if isSearching && results.isEmpty {
                    Text("No episodes match “\(query)”")
                        .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .listRowBackground(theme.color(.bg))
            .listRowSeparator(.hidden)

            if podcast.isLocal {
                ForEach(articles.pending) { item in
                    ArticlePendingRow(item: item,
                                      onRetry: { articles.retry(url: item.id) },
                                      onDismiss: { articles.dismiss(url: item.id) })
                        .listRowBackground(theme.color(.bg))
                        .listRowSeparator(.hidden)
                }
            }

            ForEach(displayedEpisodes) { ep in
                EpisodeRow(episode: ep,
                           downloadState: downloads.state(for: ep),
                           snippet: snippet(for: ep),
                           onPlay: { play(ep) },
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
                Button { showTranscripts = true } label: { Image(systemName: "text.quote") }
                    .accessibilityLabel("Browse transcripts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { ShowSettingsSheet(podcast: podcast) }
        .sheet(isPresented: $showTranscripts) { ShowTranscriptsView(podcast: podcast) }
        .onChange(of: query) { _, _ in runSearch() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
            TextField("Search episodes & transcripts", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("episode-search")
            if isSearching {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.color(.textTertiary))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
        .padding(.top, 8)
    }

    private func runSearch() {
        guard isSearching else { results = []; return }
        results = PodcastEpisodeSearch(index: searchIndexBox.index).search(query, in: podcast)
    }

    // Search results that hit a transcript cue jump to that moment; metadata matches start
    // from the episode's saved position via the normal play path.
    private func play(_ ep: Episode) {
        playback.play(ep)
        if let start = results.first(where: { $0.episode.guid == ep.guid })?.snippetStartTime {
            playback.seek(toFraction: start / max(1, ep.duration))
        }
    }

    private func deleteEpisode(_ ep: Episode) {
        downloads.delete(ep)   // audio file + download record
        subscriptions.archiveEpisode(ep, keepTranscript: appSettings.keepTranscriptsOnDelete)
    }

    private func refresh() async {
        guard !podcast.isLocal else { return }
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
                Button(podcast.isLocal ? "Delete Show" : "Unsubscribe") {
                    subscriptions.unsubscribe(podcast); dismiss()
                }
                .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.color(.accent))
            }
            Spacer()
        }
        .padding(.top, 12)
    }
}
