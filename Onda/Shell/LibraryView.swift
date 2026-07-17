//  LibraryView.swift
import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(DownloadManager.self) private var downloads
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
    @State private var showSearch = false
    @State private var showClips = false
    @State private var settingsPodcast: Podcast?
    @State private var unsubscribeTarget: Podcast?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                        Spacer()
                        Button { showClips = true } label: {
                            Image(systemName: "bookmark")
                                .accessibilityLabel("Clips")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain)
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20).padding(.top, 56)

                    if !shows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            let allEpisodes = shows.flatMap(\.episodes)
                            HStack(spacing: 10) {
                                ForEach(SmartQueue.allCases, id: \.self) { sq in
                                    let isEmpty = !sq.hasMatches(in: allEpisodes)
                                    Button {
                                        playback.startSmartQueue(sq.apply(to: allEpisodes))
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
                        .padding(.top, 16)
                    }

                    if shows.isEmpty {
                        Text("No shows yet — find some in Discover")
                            .foregroundStyle(theme.color(.textTertiary))
                            .frame(maxWidth: .infinity).padding(.top, 80)
                    } else {
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(shows) { show in
                                NavigationLink(value: show) { ShowCard(podcast: show) }
                                    .buttonStyle(.plain)
                                    .contextMenu { contextMenu(for: show) }
                            }
                        }
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
