//  LibraryView.swift
import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed },
           sort: \Podcast.title) private var shows: [Podcast]

    private let cols = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                        Spacer()
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.color(.textSecondary))
                                .frame(width: 36, height: 36)
                                .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20).padding(.top, 56)

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
        }
    }
}
