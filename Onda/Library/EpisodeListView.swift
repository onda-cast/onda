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
    @State private var filter: EpisodeFilter
    @State private var query = ""
    @State private var results: [EpisodeSearchResult] = []
    @State private var pendingUnsubscribe = false
    @State private var pendingDownloadDelete: Episode?
    @State private var detailEpisode: Episode?

    init(podcast: Podcast) {
        self.podcast = podcast
        // Don't open a freshly-subscribed show onto an empty "no downloads" screen.
        let hasDownloads = podcast.episodes.contains { $0.downloadedFile != nil }
        _filter = State(initialValue: hasDownloads ? .downloaded : .all)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var episodes: [Episode] {
        filter.apply(to: podcast.episodes)
    }

    private func snippet(for ep: Episode) -> String? {
        results.first { $0.episode.guid == ep.guid }?.snippet
    }

    // List (not ScrollView) so rows get native HIG swipe actions; context menu stays as
    // the redundant secondary access per Apple's guidance.
    var body: some View {
        // Computed once per render — `episodes` faults/filters podcast.episodes, so evaluating
        // it twice below (once for the empty-state check, once inside displayedEpisodes) did
        // that work twice every render.
        let currentEpisodes = episodes
        let shown = isSearching ? results.map(\.episode) : currentEpisodes
        List {
            Group {
                header
                searchBar
                if !isSearching {
                    SegmentedRow(options: EpisodeFilter.allCases.map { ($0.label, $0) },
                                 selection: filter) { filter = $0 }
                }
                if !isSearching && currentEpisodes.isEmpty && filter == .downloaded {
                    Button { filter = .all } label: {
                        Text("No downloads yet — show all episodes")
                            .scaledFont(13, weight: .semibold).foregroundStyle(theme.color(.accent))
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }.buttonStyle(.plain)
                }
                if isSearching && results.isEmpty {
                    BrutalEmptyState("No episodes match “\(query)”")
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

            ForEach(shown) { ep in
                EpisodeRow(episode: ep,
                           snippet: snippet(for: ep),
                           onPlay: { play(ep) },
                           onDownload: {
                               switch downloads.state(for: ep) {
                               case .downloaded: pendingDownloadDelete = ep   // confirm, don't delete on tap
                               case .failed:     downloads.retryManually(guid: ep.guid)
                               case .downloading: break
                               case .none:       downloads.download(ep)
                               }
                           },
                           onOpen: { detailEpisode = ep })
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
        // The tab bar + mini-player are a RootView overlay, not real safe area — without this
        // inset the last row scrolls to a stop half-hidden behind them (reported on device).
        .contentMargins(.bottom, BottomChrome.clearance, for: .scrollContent)
        .miniPlayerAutoHide(playback)
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
                    .accessibilityLabel("Show settings")
                    .accessibilityIdentifier("show-settings-button")
            }
        }
        .sheet(isPresented: $showSettings) { ShowSettingsSheet(podcast: podcast) }
        .sheet(isPresented: $showTranscripts) { ShowTranscriptsView(podcast: podcast) }
        .sheet(item: $detailEpisode) { EpisodeDetailView(episode: $0) }
        .onChange(of: query) { _, _ in runSearch() }
        .confirmationDialog(podcast.isLocal
            ? "Delete \(podcast.title)?"
            : "Unsubscribe from \(podcast.title)?",
            isPresented: $pendingUnsubscribe,
            titleVisibility: .visible) {
                Button(podcast.isLocal ? "Delete" : "Unsubscribe", role: .destructive) {
                    subscriptions.unsubscribe(podcast); dismiss()
                }
                Button("Cancel", role: .cancel) {}
        } message: {
            Text(podcast.isLocal
                ? "Permanently deletes every converted article in this show. This can't be undone."
                : podcast.isPrivateFeed
                ? "Removes this show and frees its downloads. Re-adding it requires the original "
                + "private feed URL \u{2014} it can't be found by search."
                : "Removes this show and frees its downloads. Transcripts follow your keep-transcripts setting.")
        }
        .confirmationDialog("Delete this download?",
                            isPresented: Binding(get: { pendingDownloadDelete != nil },
                                                 set: { if !$0 { pendingDownloadDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDownloadDelete) { ep in
            Button("Delete Download", role: .destructive) { downloads.delete(ep) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Frees the audio file. You can stream or re-download it later.") }
    }

    private var searchBar: some View {
        BrutalSearchField("Search episodes & transcripts", text: $query,
                          fieldIdentifier: "episode-search")
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
        playback.showNowPlaying = true   // play from the show page opens the full player
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
            ArtworkView(url: podcast.artworkURL, seed: podcast.title, cached: true)
                .frame(width: 96, height: 96).hardShadow(offset: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(podcast.title).brutalHeader(size: 20).foregroundStyle(theme.color(.text))
                Text(podcast.category).scaledFont(13)
                    .foregroundStyle(theme.color(.textTertiary))
                Button { pendingUnsubscribe = true } label: {
                    Text(podcast.isLocal ? "Delete Show" : "Unsubscribe")
                        .scaledFont(13, weight: .bold).foregroundStyle(.red)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        .frame(minHeight: 44).contentShape(Rectangle())   // HIG tap target
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.top, 12)
    }
}
