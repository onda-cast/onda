//  LibraryView.swift
import SwiftUI
import SwiftData

enum LibraryLayout: String, CaseIterable {
    case grid, compact, text
    var label: String {
        switch self {
        case .grid: return "Grid"
        case .compact: return "Compact"
        case .text: return "Text Only"
        }
    }
    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .compact: return "rectangle.grid.1x2"
        case .text: return "text.justify"
        }
    }
}

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(DownloadManager.self) private var downloads
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage("librarySort") private var sortRaw = LibrarySort.alphabetical.rawValue
    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .alphabetical }
    private var sortedShows: [Podcast] { sort.sorted(shows) }
    @State private var showSearch = false
    @State private var showClips = false
    @State private var settingsPodcast: Podcast?
    @State private var unsubscribeTarget: Podcast?
    @State private var toast: String?
    @State private var pendingSmartQueue: [Episode]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                        Spacer()
                        Button { showClips = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bookmark")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("CLIPS").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 10).frame(height: 36)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Clips")
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain)
                        layoutMenu
                    }
                    .padding(.horizontal, 20).padding(.top, 56)

                    if !shows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            let allEpisodes = shows.flatMap(\.episodes)
                            HStack(spacing: 10) {
                                ForEach(SmartQueue.allCases, id: \.self) { sq in
                                    let isEmpty = !sq.hasMatches(in: allEpisodes)
                                    Button {
                                        startSmartQueue(sq.apply(to: allEpisodes))
                                    } label: {
                                        Text(sq.label.uppercased())
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.color(.textSecondary))
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isEmpty)
                                    .opacity(isEmpty ? 0.4 : 1)
                                }
                            }.padding(.horizontal, 20)
                        }
                        // Fade the right edge so it reads as "more chips off-screen, scroll me".
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.88),
                                .init(color: .clear, location: 1)
                            ], startPoint: .leading, endPoint: .trailing)
                        )
                        .padding(.top, 16)
                    }

                    if shows.isEmpty {
                        Text("No shows yet — find some in Discover")
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    } else {
                        libraryContent
                            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 120)
                    }
                }
            }
            .background(theme.color(.bg))
            .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
            .sheet(isPresented: $showSearch) { LibrarySearchView() }
            .sheet(isPresented: $showClips) { ClipsView() }
            .sheet(item: $settingsPodcast) { ShowSettingsSheet(podcast: $0) }
            .confirmationDialog("Unsubscribe from \(unsubscribeTarget?.title ?? "")?",
                                isPresented: Binding(get: { unsubscribeTarget != nil },
                                                     set: { if !$0 { unsubscribeTarget = nil } }),
                                titleVisibility: .visible, presenting: unsubscribeTarget) { show in
                Button("Unsubscribe", role: .destructive) { subscriptions.unsubscribe(show) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removes this show and frees its downloads. Transcripts follow your keep-transcripts setting.")
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
                    Text(toast)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(theme.color(.accent)).brutalBorder(width: 2)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // Only confirm when there's a hand-built queue to lose; otherwise start straight away.
    private func startSmartQueue(_ episodes: [Episode]) {
        if playback.queue.isEmpty {
            playback.startSmartQueue(episodes)
        } else {
            pendingSmartQueue = episodes
        }
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Layout", selection: $layoutRaw) {
                ForEach(LibraryLayout.allCases, id: \.rawValue) { l in
                    Label(l.label, systemImage: l.icon).tag(l.rawValue)
                }
            }
            Picker("Sort", selection: $sortRaw) {
                ForEach(LibrarySort.allCases, id: \.rawValue) { s in
                    Label(s.label, systemImage: s.icon).tag(s.rawValue)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.color(.textSecondary))
                .frame(width: 36, height: 36)
                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
        }
        .accessibilityLabel("Library view options")
    }

    @ViewBuilder private var libraryContent: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: cols, spacing: 18) {
                ForEach(sortedShows) { show in
                    NavigationLink(value: show) { ShowCard(podcast: show) }
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
                ArtworkView(url: show.artworkURL, seed: show.title)
                    .frame(width: 52, height: 52).brutalBorder(width: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                    .lineLimit(1)
                Text(show.episodes.first?.title ?? "No episodes")
                    .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13))
                .foregroundStyle(theme.color(.textTertiary))
        }
        .padding(showArt ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
    }

    @ViewBuilder private func contextMenu(for show: Podcast) -> some View {
        Button { checkUpdates(show) } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
        Button { downloadLatest(show) } label: { Label("Download Latest", systemImage: "arrow.down.circle") }
        Button { settingsPodcast = show } label: { Label("Show Settings", systemImage: "gearshape") }
        Button { subscriptions.markAllPlayed(for: show) } label: {
            Label("Mark All Played", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { unsubscribeTarget = show } label: {
            Label("Unsubscribe", systemImage: "trash")
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
