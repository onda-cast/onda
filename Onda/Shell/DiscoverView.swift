//  DiscoverView.swift
import SwiftUI
import SwiftData

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(ITunesSearchClientBox.self) private var clientBox
    @Environment(RecommendationService.self) private var recs
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]

    @State private var query = ""
    @State private var results: [PodcastDTO] = []
    @State private var trending: [PodcastDTO] = []
    @State private var loading = false
    @State private var shake: ShakeState?
    @State private var shakeCount = 0
    @State private var dealID = 0   // bumps when shake results land; replays the deal-in animation
    @State private var mode: DiscoverMode = .browse
    @FocusState private var searchFocused: Bool

    private enum DiscoverMode: Hashable { case browse, forYou }

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
    private var followedCategories: [String] {
        Array(Set(subs.map(\.category))).sorted()
    }

    private func isSubscribed(_ dto: PodcastDTO) -> Bool {
        dto.feedUrl.map(subscribedFeeds.contains) ?? false
    }

    // MARK: Browse sub-tab (search, categories, trending, shake)

    @ViewBuilder private var browseTab: some View {
        searchField
        categoryChips
        listHeader
        Group {
            ForEach(Array(listItems.enumerated()), id: \.element.collectionId) { i, dto in
                let row = TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) {
                    Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: dto) }
                }
                if shake != nil {
                    DealtCard(index: i) { row }
                } else {
                    row
                }
            }
        }
        .id(dealID)   // new identity per shake so every deal replays from the top
    }

    // MARK: For You sub-tab (recommendations)

    @ViewBuilder private var forYouTab: some View {
        HStack {
            Text("Recommended for you").brutalHeader(size: 13)
                .foregroundStyle(theme.color(.textTertiary))
            Spacer()
            Button {
                Task { await recs.refresh(followedCategories: followedCategories) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.color(.textSecondary))
                    .frame(width: 34, height: 34)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }
            .buttonStyle(.plain).disabled(recs.isLoading)
        }
        if recs.isLoading && recs.recommendations.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(theme.color(.accent))
                Text("Finding shows for you…").font(.system(size: 13))
                    .foregroundStyle(theme.color(.textTertiary))
            }.padding(.top, 40).frame(maxWidth: .infinity)
        } else if recs.recommendations.isEmpty {
            Text("Follow a few shows and clip moments you love — recommendations get sharper as Onda learns your taste.")
                .font(.system(size: 13)).foregroundStyle(theme.color(.textTertiary))
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 50)
        } else {
            ForEach(recs.recommendations) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    TrendingRow(dto: rec.dto, isSubscribed: isSubscribed(rec.dto)) {
                        Task { [subscriptions] in _ = try? await subscriptions.subscribe(to: rec.dto) }
                    }
                    if let reason = rec.reasonLine {
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(theme.color(.textTertiary))
                            .padding(.leading, 2)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { recs.dismiss(rec) } label: {
                        Label("Not interested", systemImage: "hand.thumbsdown")
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Discover").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                    Spacer()
                    Button { triggerShake() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "shuffle").font(.system(size: 14, weight: .bold))
                            Text("SHUFFLE").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(theme.color(.textSecondary))
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle new podcasts")
                    .accessibilityHint("Also works by shaking your phone")
                }
                .padding(.top, 56)

                SegmentedRow(options: [("Browse", DiscoverMode.browse), ("For You", .forYou)],
                             selection: mode) { mode = $0 }

                if mode == .browse { browseTab } else { forYouTab }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        // Dice-cup wobble the moment a shake registers — feedback that the roll is happening,
        // before the network round-trip lands the results.
        .phaseAnimator([0, -1.6, 1.9, -1.2, 0.8, 0], trigger: shakeCount) { view, angle in
            view.rotationEffect(.degrees(angle), anchor: .center)
        } animation: { _ in .spring(duration: 0.07, bounce: 0.5) }
        // Tapping anywhere (simultaneous so buttons still work) or scrolling dismisses the keyboard.
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        .scrollDismissesKeyboard(.immediately)
        .background(theme.color(.bg))
        .task { await loadTrending() }
        .task { await recs.refreshIfStale(followedCategories: followedCategories) }
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { shake = nil }
            Task { await runSearch(new) }
        }
        .onShake { triggerShake() }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakeCount)
        .sensoryFeedback(.success, trigger: dealID)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
            TextField("Search shows & episodes", text: $query)
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
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
            shakeHeader(shake)
                .id(dealID)
                .transition(.asymmetric(
                    insertion: .scale(scale: 1.35, anchor: .leading).combined(with: .opacity),
                    removal: .opacity))
        } else {
            Text(results.isEmpty ? "Trending Today" : "Results")
                .brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
        }
    }

    private func shakeHeader(_ shake: ShakeState) -> some View {
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
    }

    private func subtitle(for shake: ShakeState) -> String {
        let names = shake.categories
        if shake.usedFallback || names.isEmpty { return "A random mix by topic" }
        if names.count == 1 { return "Because you follow \(names[0])" }
        return "Because you follow \(names[0]) & \(names[1])"
    }

    // Shared entry point for the shake gesture and the visible Shuffle button.
    private func triggerShake() {
        mode = .browse   // shake results live in Browse
        shakeCount += 1
        Task { await runShake() }
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
        // Nothing new to show → stay on Trending rather than an empty "success" state.
        guard !result.picks.isEmpty else { return }
        let title = Self.shakeTitles.randomElement() ?? "Shaken for you"
        withAnimation(.spring(duration: 0.35, bounce: 0.35)) {
            shake = ShakeState(picks: result.picks, categories: result.categories,
                               usedFallback: result.usedFallback, title: title)
            dealID += 1   // re-deals the cards and fires the landing haptic
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
        if !results.isEmpty { recs.recordSearch(t) }   // an interest signal for future recs
    }
}
