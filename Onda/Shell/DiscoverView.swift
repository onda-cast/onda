//  DiscoverView.swift
import SwiftUI
import SwiftData

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(ITunesSearchClientBox.self) private var clientBox
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]

    @State private var query = ""
    @State private var results: [PodcastDTO] = []
    @State private var trending: [PodcastDTO] = []
    @State private var loading = false

    private let categories = ["Technology", "Comedy", "News", "Business", "Health", "Science"]
    private var subscribedFeeds: Set<URL> { Set(subs.map(\.feedURL)) }

    private func isSubscribed(_ dto: PodcastDTO) -> Bool {
        dto.feedUrl.map(subscribedFeeds.contains) ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Discover").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                    .padding(.top, 56)

                searchField
                categoryChips

                Text(results.isEmpty ? "Trending Today" : "Results")
                    .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))

                ForEach(results.isEmpty ? trending : results, id: \.collectionId) { dto in
                    TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                        Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: dto) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .background(theme.color(.bg))
        .task { await loadTrending() }
        .onChange(of: query) { _, new in Task { await runSearch(new) } }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
            TextField("Search shows & episodes", text: $query)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button { query = cat } label: {
                        Text(cat).brutalHeader(size: 11.5).foregroundStyle(theme.color(.text))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func loadTrending() async {
        guard trending.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let ids = try await clientBox.client.topChartIds(limit: 25)
            trending = try await clientBox.client.lookup(ids: Array(ids.prefix(20)))
        } catch { trending = [] }
    }

    private func runSearch(_ term: String) async {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(300))   // debounce
        guard t == query.trimmingCharacters(in: .whitespaces) else { return }
        results = (try? await clientBox.client.search(term: t)) ?? []
    }
}
