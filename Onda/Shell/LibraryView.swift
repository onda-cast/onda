//  LibraryView.swift
import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
    @State private var showSearch = false
    @State private var showClips = false

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
                            HStack(spacing: 10) {
                                ForEach(SmartQueue.allCases, id: \.self) { sq in
                                    let episodes = sq.apply(to: shows.flatMap(\.episodes))
                                    Button {
                                        playback.startSmartQueue(episodes)
                                    } label: {
                                        Text(sq.label.uppercased())
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.color(.textSecondary))
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(episodes.isEmpty)
                                    .opacity(episodes.isEmpty ? 0.4 : 1)
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
        }
    }
}
