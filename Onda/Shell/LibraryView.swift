//  LibraryView.swift
import SwiftUI
import SwiftData

private struct ChipsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ChipsViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(DownloadManager.self) private var downloads
    @Environment(ArticleConversionService.self) private var articles
    @Environment(FeedRefreshService.self) private var refresh
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]
    // Chips are downloaded-only lenses, so their candidate set comes from the small
    // DownloadedFile table — never from a per-episode scan of the whole library.
    @Query private var downloadedFiles: [DownloadedFile]
    private var chipCandidates: [Episode] { SmartQueue.downloadedCandidates(downloadedFiles) }

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage("librarySort") private var sortRaw = LibrarySort.alphabetical.rawValue
    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .alphabetical }
    // Stale-while-revalidate: last run's keys sort instantly; a background recompute lands
    // fresh keys each time the Library appears. Sorting must never fault episodes (see
    // LibrarySortKeys) — that was the multi-second tab switch on device.
    @State private var sortKeys = LibrarySortKeys.cached() ?? LibrarySortKeys()
    @Environment(\.modelContext) private var modelContext
    private var sortedShows: [Podcast] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = sort.sorted(shows, keys: sortKeys)
        if UITestScaleSeed.isActive {
            NSLog("PERFAPP sortedShows %.0fms n=%d", (CFAbsoluteTimeGetCurrent() - t0) * 1000, result.count)
        }
        return result
    }
    @State private var showSearch = false
    @State private var showClips = false
    @State private var showAddByURL = false
    @State private var settingsPodcast: Podcast?
    @State private var unsubscribeTarget: Podcast?
    // Right-edge fade is a "scroll me" affordance — only meaningful when the chips actually overflow.
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0
    private var chipsOverflow: Bool { chipsContentWidth > chipsViewportWidth + 1 }
    @State private var toast: String?
    @State private var pendingSmartQueue: [Episode]?
    // Chips FILTER the library (like Discover's chips); queue replacement only happens via the
    // explicit Play All button inside a filtered view.
    @State private var activeFilter: SmartQueue?
    @State private var detailEpisode: Episode?
    @State private var pendingDownloadDelete: Episode?

    // Anchor id for the layout-menu button's scroll-to-top (tapping it opens the sort/layout
    // menu, which is easy to miss if the list is scrolled down — jump up first so the header
    // and the reordered/relaid-out content are both visible).
    private let topAnchor = "library-top"
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityIdentifier("library-title")
                        Spacer()
                        Button { showClips = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bookmark")
                                    .scaledFont(15, weight: .semibold)
                                Text("CLIPS").scaledFont(12, weight: .bold)
                            }
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 10).frame(height: 44)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Clips")
                        Button { showAddByURL = true } label: {
                            Image(systemName: "link.badge.plus")
                                .scaledFont(16, weight: .semibold)
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 44, height: 44)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Add by Link")
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .scaledFont(17, weight: .semibold)
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 44, height: 44)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Search Transcripts")
                        layoutMenu
                    }
                    .padding(.horizontal, 20).padding(.top, 56)

                    if !shows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            let allEpisodes = chipCandidates
                            HStack(spacing: 10) {
                                ForEach(SmartQueue.allCases, id: \.self) { sq in
                                    let isEmpty = !sq.hasMatches(in: allEpisodes)
                                    let isActive = activeFilter == sq
                                    // Filter toggle — same mental model as Discover's chips. The
                                    // queue is only touched by the explicit Play All button.
                                    Button {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            activeFilter = isActive ? nil : sq
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isActive {
                                                Image(systemName: "checkmark")
                                                    .scaledFont(10, weight: .black)
                                            }
                                            Text(sq.label.uppercased())
                                                .scaledFont(12, weight: .bold)
                                        }
                                        .foregroundStyle(isActive ? .white : theme.color(.textSecondary))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(isActive ? theme.color(.accentStrong)
                                                             : theme.color(.bgElevated))
                                        .brutalBorder(width: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isEmpty && !isActive)
                                    .opacity(isEmpty && !isActive ? 0.4 : 1)
                                    .accessibilityAddTraits(isActive ? .isSelected : [])
                                }
                            }
                            .padding(.horizontal, 20)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChipsWidthKey.self, value: g.size.width)
                            })
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChipsViewportWidthKey.self, value: g.size.width)
                        })
                        .onPreferenceChange(ChipsWidthKey.self) { chipsContentWidth = $0 }
                        .onPreferenceChange(ChipsViewportWidthKey.self) { chipsViewportWidth = $0 }
                        // Fade the right edge as a "more chips off-screen, scroll me" hint — but only
                        // when the chips actually overflow; a full-width rectangle mask is a no-op.
                        .mask {
                            if chipsOverflow {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .leading, endPoint: .trailing)
                            } else {
                                Rectangle()
                            }
                        }
                        .padding(.top, 16)
                    }

                    // The Articles show is only created on first successful conversion, so
                    // in-flight/failed first-article rows would otherwise have nowhere to
                    // render. Surface them here until the show exists; once it does, they
                    // show only inside its episode list (no double display).
                    if !articles.pending.isEmpty
                        && !shows.contains(where: { $0.feedURL == ArticleConversionService.articlesFeedURL }) {
                        pendingArticlesSection
                    }

                    if shows.isEmpty {
                        BrutalEmptyState("No shows yet", detail: "Find some in Discover.")
                    } else if let filter = activeFilter {
                        filteredEpisodeList(filter)
                            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, BottomChrome.clearance)
                    } else {
                        libraryContent
                            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, BottomChrome.clearance)
                    }
                }
                .id(topAnchor)
            }
            .background(theme.color(.bg))
            .refreshable { await pullRefresh() }
            .miniPlayerAutoHide(playback)
            .task { await refreshSortKeys() }
            // A download landing while the grid is on screen changes a show's badge count.
            .onChange(of: downloads.completedDownloadCount) { _, _ in Task { await refreshSortKeys() } }
            .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
            .sheet(isPresented: $showSearch) { LibrarySearchView() }
            .sheet(isPresented: $showClips) { ClipsView() }
            .sheet(isPresented: $showAddByURL) { AddByURLSheet().presentationDetents([.medium, .large]) }
            .sheet(item: $settingsPodcast) { ShowSettingsSheet(podcast: $0) }
            .sheet(item: $detailEpisode) { EpisodeDetailView(episode: $0) }
            .confirmationDialog("Delete this download?",
                                isPresented: Binding(get: { pendingDownloadDelete != nil },
                                                     set: { if !$0 { pendingDownloadDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDownloadDelete) { ep in
                Button("Delete Download", role: .destructive) {
                    downloads.delete(ep)
                    Task { await refreshSortKeys() }   // removing a download changes the badge count
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The episode stays in your library and can stream or re-download.")
            }
            .confirmationDialog(unsubscribeTarget?.isLocal == true
                                ? "Delete \(unsubscribeTarget?.title ?? "")?"
                                : "Unsubscribe from \(unsubscribeTarget?.title ?? "")?",
                                isPresented: Binding(get: { unsubscribeTarget != nil },
                                                     set: { if !$0 { unsubscribeTarget = nil } }),
                                titleVisibility: .visible, presenting: unsubscribeTarget) { show in
                Button(show.isLocal ? "Delete" : "Unsubscribe", role: .destructive) {
                    subscriptions.unsubscribe(show)
                }
                Button("Cancel", role: .cancel) {}
            } message: { show in
                Text(show.isLocal
                     ? "Permanently deletes every converted article in this show. This can't be undone."
                     : show.isPrivateFeed
                     ? "Removes this show and frees its downloads. Re-adding it requires the original "
                       + "private feed URL \u{2014} it can't be found by search."
                     : "Removes this show and frees its downloads. Transcripts follow your keep-transcripts setting.")
            }
            .confirmationDialog("Replace your queue?",
                                isPresented: Binding(get: { pendingSmartQueue != nil },
                                                     set: { if !$0 { pendingSmartQueue = nil } }),
                                titleVisibility: .visible, presenting: pendingSmartQueue) { eps in
                Button("Replace \(playback.queue.count) queued", role: .destructive) {
                    playback.startSmartQueue(eps)
                }
                Button("Cancel", role: .cancel) {}
            } message: { eps in
                Text("Starts \(eps.count) episode\(eps.count == 1 ? "" : "s") and clears your current queue.")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    BrutalToast(text: toast)
                        .padding(.bottom, BottomChrome.clearance)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear { scrollProxy = proxy }
            }
        }
    }

    /// Pull-to-refresh: force a feed check for every subscribed show (bypasses the 15-min
    /// foreground throttle), then refresh the sort keys so a new episode reorders the grid.
    /// (@Sendable refreshable closure — hop through here, same pattern as Discover.)
    private func pullRefresh() async {
        await refresh.refreshAll(force: true)
        await refreshSortKeys()
    }

    /// Recompute the cached sort keys / badge counts off the main actor. Called on appear,
    /// pull-to-refresh, and after in-view mutations that change a show's unplayed-downloaded
    /// count (mark-all-played, download delete, download completion) — without this the "new
    /// episodes" badge would show a stale count until the next tab switch.
    private func refreshSortKeys() async {
        let fresh = await LibrarySortKeys.computeInBackground(container: modelContext.container)
        if fresh != sortKeys { sortKeys = fresh }
    }

    // Only confirm when there's a hand-built queue to lose; otherwise start straight away.
    private func startSmartQueue(_ episodes: [Episode]) {
        if playback.queue.isEmpty {
            playback.startSmartQueue(episodes)
        } else {
            pendingSmartQueue = episodes
        }
    }

}

// MARK: - Layout menu, show list, and context actions
extension LibraryView {
    private var layoutMenu: some View {
        Menu {
            // Header states the active value; the inline Picker checkmarks the selected row —
            // so the current sort/layout is legible without cross-referencing.
            Section("Sort · \(sort.label)") {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases, id: \.rawValue) { s in
                        Label(s.label, systemImage: s.icon).tag(s.rawValue)
                    }
                }
            }
            Section("Layout · \(layout.label)") {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(LibraryLayout.allCases, id: \.rawValue) { l in
                        Label(l.label, systemImage: l.icon).tag(l.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(theme.color(.textSecondary))
                .frame(width: 44, height: 44)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
        }
        .accessibilityLabel("Library view options")
        // simultaneousGesture (not onTapGesture): a Menu's own tap opens the menu; this rides
        // along without stealing that tap, same moment the menu appears.
        .simultaneousGesture(TapGesture().onEnded {
            withAnimation { scrollProxy?.scrollTo(topAnchor, anchor: .top) }
        })
    }

    private var pendingArticlesSection: some View {
        VStack(spacing: 10) {
            ForEach(articles.pending) { item in
                ArticlePendingRow(item: item,
                                  onRetry: { articles.retry(url: item.id) },
                                  onDismiss: { articles.dismiss(url: item.id) })
            }
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    @ViewBuilder private var libraryContent: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: cols, spacing: 18) {
                ForEach(sortedShows) { show in
                    NavigationLink(value: show) {
                        ShowCard(podcast: show,
                                unplayedCount: sortKeys.unplayedCount[show.feedURL.absoluteString] ?? 0)
                    }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: show) }
                }
            }
        case .compact, .text:
            LazyVStack(spacing: 10) {
                ForEach(sortedShows) { show in
                    NavigationLink(value: show) { rowCard(show, showArt: layout == .compact) }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: show) }
                }
            }
        }
    }

    private func rowCard(_ show: Podcast, showArt: Bool) -> some View {
        HStack(spacing: 12) {
            if showArt {
                ArtworkView(url: show.artworkURL, seed: show.title, cached: true)
                    .frame(width: 52, height: 52).brutalBorder(width: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(1)
                LatestEpisodeSubtitle(podcast: show)
            }
            // Claim the row's free width so a long title truncates here instead of sliding under
            // the chevron (the overlap seen in compact/text layouts).
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").scaledFont(13)
                .foregroundStyle(theme.color(.textTertiary))
        }
        .padding(showArt ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
    }

    @ViewBuilder private func contextMenu(for show: Podcast) -> some View {
        if !show.isLocal {
            Button { checkUpdates(show) } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
            Button { downloadLatest(show) } label: { Label("Download Latest", systemImage: "arrow.down.circle") }
        }
        Button { settingsPodcast = show } label: { Label("Show Settings", systemImage: "gearshape") }
        Button {
            subscriptions.markAllPlayed(for: show)
            Task { await refreshSortKeys() }   // drop this show's badge to 0 immediately
        } label: {
            Label("Mark All Played", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { unsubscribeTarget = show } label: {
            Label(show.isLocal ? "Delete Articles Show" : "Unsubscribe", systemImage: "trash")
        }
    }

    private func checkUpdates(_ show: Podcast) {
        let before = show.episodes.count
        Task {
            try? await subscriptions.refreshEpisodes(for: show)
            let added = show.episodes.count - before
            showToast(added == 0 ? "\(show.title): up to date"
                      : "\(show.title): \(added) new episode\(added == 1 ? "" : "s")")
        }
    }

    private func downloadLatest(_ show: Podcast) {
        guard let latest = show.episodes.max(by: { $0.publishDate < $1.publishDate }) else { return }
        if latest.downloadedFile == nil { downloads.download(latest) }
        showToast(latest.downloadedFile == nil ? "Downloading \(show.title)" : "Latest already downloaded")
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Chip-filtered episode list
extension LibraryView {
    private func filterHeader(_ episodes: [Episode]) -> some View {
        HStack {
            Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
                .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            Spacer()
            Button {
                startSmartQueue(episodes)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").scaledFont(11, weight: .bold)
                    Text("PLAY ALL").scaledFont(12, weight: .bold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 34)
                .background(theme.color(.accentStrong)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play all \(episodes.count) episodes")
        }
        .padding(.bottom, 6)
    }

    // Same download-tap semantics as EpisodeListView's rows.
    private func downloadAction(_ ep: Episode) {
        switch downloads.state(for: ep) {
        case .downloaded: pendingDownloadDelete = ep
        case .failed:     downloads.retryManually(guid: ep.guid)
        case .downloading: break
        case .none:       downloads.download(ep)
        }
    }

    /// Filtered episodes grouped per show. Groups are ordered by each show's first appearance in
    /// the filter's own ordering (so "Recently Added" still leads with the freshest show), and
    /// episodes inside a group keep the filter's order. The flattened group order is what
    /// Play All queues — the queue matches exactly what's on screen.
    private func groupedByShow(_ episodes: [Episode]) -> [(show: Podcast, episodes: [Episode])] {
        var order: [URL] = []
        var byShow: [URL: (show: Podcast, episodes: [Episode])] = [:]
        for ep in episodes {
            guard let pod = ep.podcast else { continue }
            if byShow[pod.feedURL] == nil {
                order.append(pod.feedURL)
                byShow[pod.feedURL] = (pod, [])
            }
            byShow[pod.feedURL]?.episodes.append(ep)
        }
        return order.compactMap { byShow[$0] }
    }

    /// The library content while a chip filter is active: matching episodes across all shows,
    /// grouped by show. Tapping a row plays that one episode; only Play All replaces the queue.
    @ViewBuilder func filteredEpisodeList(_ filter: SmartQueue) -> some View {
        let groups = groupedByShow(filter.apply(to: chipCandidates))
        let episodes = groups.flatMap(\.episodes)
        if episodes.isEmpty {
            BrutalEmptyState("No \(filter.label.lowercased()) episodes")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                filterHeader(episodes)
                // LazyVStack is load-bearing: with a real library, "Unplayed" can be hundreds of
                // episodes — an eager ForEach builds every row in one main-thread layout pass and
                // freezes the page (reported on device). Lazy matches libraryContent's grid/list.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.show.feedURL) { group in
                        Text(group.show.title)
                            .brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                            .lineLimit(1)
                            .padding(.top, 14).padding(.bottom, 2)
                        ForEach(group.episodes, id: \.guid) { ep in
                            EpisodeRow(episode: ep,
                                       downloadState: downloads.state(for: ep),
                                       onPlay: { playback.play(ep) },
                                       onDownload: { downloadAction(ep) },
                                       onOpen: { detailEpisode = ep })
                        }
                    }
                }
            }
        }
    }
}
