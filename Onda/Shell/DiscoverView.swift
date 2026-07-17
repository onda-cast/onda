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
    @State private var shake: ShakeState?
    @State private var shakeCount = 0

    private static let shakeTitles = [
        "Shaken for you", "Look what rolled in", "New podcasts drifting in"
    ]

    private struct ShakeState {
        var picks: [PodcastDTO]
        var categories: [String]
        var usedFallback: Bool
        var title: String
    }

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

                listHeader

                ForEach(listItems, id: \.collectionId) { dto in
                    TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                        Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: dto) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .background(theme.color(.bg))
        .task { await loadTrending() }
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { shake = nil }
            Task { await runSearch(new) }
        }
        .onShake {
            shakeCount += 1
            Task { await runShake() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakeCount)
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

    private var listItems: [PodcastDTO] {
        shake?.picks ?? (results.isEmpty ? trending : results)
    }

    @ViewBuilder private var listHeader: some View {
        if let shake {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(shake.title).brutalHeader(size: 13)
                        .foregroundStyle(theme.color(.textTertiary))
                    Spacer()
                    Button { withAnimation { self.shake = nil } } label: {
                        Text("Back to Trending")
                            .font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
                Text(subtitle(for: shake)).font(.system(size: 12))
                    .foregroundStyle(theme.color(.textTertiary))
            }
        } else {
            Text(results.isEmpty ? "Trending Today" : "Results")
                .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
        }
    }

    private func subtitle(for shake: ShakeState) -> String {
        let names = shake.categories
        if shake.usedFallback || names.isEmpty { return "A random mix by topic" }
        if names.count == 1 { return "Because you follow \(names[0])" }
        return "Because you follow \(names[0]) & \(names[1])"
    }

    private func runShake() async {
        let followed = Array(Set(subs.map(\.category))).sorted()
        var rng = SystemRandomNumberGenerator()
        let result = await shakeSuggestions(
            followedCategories: followed,
            fallbackCategories: categories,
            subscribedFeeds: subscribedFeeds,
            using: clientBox.client,
            rng: &rng)
        let title = Self.shakeTitles.randomElement() ?? "Shaken for you"
        withAnimation(.easeInOut) {
            shake = ShakeState(picks: result.picks, categories: result.categories,
                               usedFallback: result.usedFallback, title: title)
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
