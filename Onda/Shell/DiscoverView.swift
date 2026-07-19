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
    @State private var searching = false
    @State private var searchFailed = false
    @State private var shake: ShakeState?
    @State private var shakeCount = 0
    @State private var dealID = 0   // bumps when shake results land; replays the deal-in animation
    @State private var mode: DiscoverMode = .browse
    @State private var toast: String?
    @State private var unfollowTarget: PodcastDTO?
    @State private var showAddByURL = false
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

    private func subscribedPodcast(for dto: PodcastDTO) -> Podcast? {
        guard let feed = dto.feedUrl else { return nil }
        return subs.first { $0.feedURL == feed }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var trending: [PodcastDTO] { clientBox.trending }
    private var loading: Bool { clientBox.trendingLoading }
    private var trendingFailed: Bool { clientBox.trendingFailed }

    // MARK: Browse sub-tab (search, categories, trending, shake)

    @ViewBuilder private var browseTab: some View {
        searchRow
        categoryChips
        listHeader
        browseStatus
        Group {
            ForEach(Array(listItems.enumerated()), id: \.element.collectionId) { i, dto in
                let row = TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) { toggleFollow(dto) }
                if shake != nil {
                    DealtCard(index: i) { row }
                } else {
                    row
                }
            }
        }
        .id(dealID)   // new identity per shake so every deal replays from the top
    }

    // Distinguish loading / error / genuinely-empty so a network failure never looks like "no results".
    @ViewBuilder private var browseStatus: some View {
        if isSearching {
            if searchFailed {
                errorRetry("Search failed — check your connection") { Task { await runSearch(query) } }
            } else if !searching && results.isEmpty {
                statusNote("No results for “\(query)”")
            }
        } else if shake == nil && trending.isEmpty {
            if loading {
                loadingRow("Loading trending…")
            } else if trendingFailed {
                errorRetry("Couldn't load trending") { Task { await clientBox.loadTrendingIfNeeded(force: true) } }
            }
        }
    }

    // MARK: For You sub-tab (recommendations)

    @ViewBuilder private var forYouTab: some View {
        HStack {
            Text(recs.isPersonalized ? "Recommended for you" : "Popular right now").brutalHeader(size: 13)
                .foregroundStyle(theme.color(.textTertiary))
            Spacer()
            Menu {
                Button {
                    Task { await recs.refresh(followedCategories: followedCategories) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    Task { await recs.refreshShowingDifferent(followedCategories: followedCategories) }
                } label: { Label("Show Different Shows", systemImage: "shuffle") }
            } label: {
                Image(systemName: "arrow.clockwise").scaledFont(14, weight: .bold)
                    .foregroundStyle(theme.color(.textSecondary))
                    .frame(width: 34, height: 34)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }
            .disabled(recs.isLoading)
            .accessibilityLabel("Refresh recommendations")
        }
        if recs.isLoading && recs.recommendations.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(theme.color(.accent))
                Text("Finding shows for you…").scaledFont(13)
                    .foregroundStyle(theme.color(.textTertiary))
            }.padding(.top, 40).frame(maxWidth: .infinity)
        } else if recs.recommendations.isEmpty {
            Text("Follow a few shows and clip moments you love — recommendations get sharper as Onda learns your taste.")
                .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 50)
        } else {
            ForEach(recs.recommendations) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    TrendingRow(dto: rec.dto, isSubscribed: isSubscribed(rec.dto)) { toggleFollow(rec.dto) }
                    if let reason = rec.reasonLine {
                        Text(reason).scaledFont(11.5).foregroundStyle(theme.color(.textTertiary))
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
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Button { triggerShake() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "shuffle").scaledFont(14, weight: .bold)
                            Text("SHUFFLE").scaledFont(12, weight: .bold)
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
        .refreshable { await pullRefresh() }
        // The Onda wave — washes across the screen the moment a shake registers, feedback
        // that the roll is happening before the network round-trip lands the results.
        .overlay {
            ShakeWaveOverlay(trigger: shakeCount)
                .ignoresSafeArea()
        }
        // Tapping anywhere (simultaneous so buttons still work) or scrolling dismisses the keyboard.
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        .scrollDismissesKeyboard(.immediately)
        .sheet(isPresented: $showAddByURL) {
            AddByURLSheet().presentationDetents([.medium, .large])
        }
        .background(theme.color(.bg))
        .task { await clientBox.loadTrendingIfNeeded() }
        .task { await recs.refreshIfStale(followedCategories: followedCategories) }
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { shake = nil }
            Task { await runSearch(new) }
        }
        .onShake { triggerShake() }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakeCount)
        .sensoryFeedback(.success, trigger: dealID)
        .confirmationDialog("Unfollow \(unfollowTarget?.collectionName ?? "")?",
                            isPresented: Binding(get: { unfollowTarget != nil },
                                                 set: { if !$0 { unfollowTarget = nil } }),
                            titleVisibility: .visible, presenting: unfollowTarget) { dto in
            Button("Unfollow", role: .destructive) {
                if let pod = subscribedPodcast(for: dto) {
                    subscriptions.unsubscribe(pod)
                    showToast("Unfollowed \(dto.collectionName)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Removes the show and frees its downloads.") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .scaledFont(14, weight: .bold).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(theme.color(.accent)).brutalBorder(width: 2).hardShadow(offset: 3)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    let selected = query.caseInsensitiveCompare(cat) == .orderedSame
                    Button { query = selected ? "" : cat } label: {
                        Text(cat).brutalHeader(size: 11.5)
                            .foregroundStyle(selected ? .white : theme.color(.text))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(selected ? theme.color(.accent) : theme.color(.bgElevated))
                            .brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
                        .scaledFont(11, weight: .bold).textCase(.uppercase)
                        .foregroundStyle(theme.color(.textSecondary))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }.buttonStyle(.plain)
            }
            Text(subtitle(for: shake)).scaledFont(12)
                .foregroundStyle(theme.color(.textTertiary))
        }
    }

    private func subtitle(for shake: ShakeState) -> String {
        let names = shake.categories
        if shake.usedFallback || names.isEmpty { return "A random mix by topic" }
        if names.count == 1 { return "Because you follow \(names[0])" }
        return "Because you follow \(names[0]) & \(names[1])"
    }
}

// MARK: - Status views
extension DiscoverView {
    func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().tint(theme.color(.accent))
            Text(text).scaledFont(13).foregroundStyle(theme.color(.textTertiary))
        }.frame(maxWidth: .infinity).padding(.top, 40)
    }

    func statusNote(_ text: String) -> some View {
        Text(text).scaledFont(13).foregroundStyle(theme.color(.textTertiary))
            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
    }

    func errorRetry(_ text: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(text).scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text("Retry").scaledFont(13, weight: .bold).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity).padding(.top, 36)
    }
}

// MARK: - Follow / toast
extension DiscoverView {
    // Follow (with a confirmation toast) or, if already following, prompt to unfollow.
    func toggleFollow(_ dto: PodcastDTO) {
        if isSubscribed(dto) {
            unfollowTarget = dto
        } else {
            Task { [subscriptions] in
                do {
                    _ = try await subscriptions.subscribe(to: dto)
                    showToast("Following \(dto.collectionName)")
                } catch {
                    showToast("Couldn't follow \(dto.collectionName)")
                }
            }
        }
    }

    func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Search & add-feed row
extension DiscoverView {
    var searchRow: some View {
        HStack(spacing: 10) {
            searchField
            Button { showAddByURL = true } label: {
                Image(systemName: "link.badge.plus")
                    .scaledFont(16, weight: .bold)
                    .foregroundStyle(theme.color(.textSecondary))
                    .frame(width: 48, height: 48)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add by Link")
            .accessibilityHint("Private podcast feeds or articles to listen to")
        }
    }

    private var searchField: some View {
        BrutalSearchField("Search shows & episodes", text: $query, focus: $searchFocused)
    }
}

// MARK: - Data loading & shake
extension DiscoverView {
    // Shared entry point for the shake gesture and the visible Shuffle button.
    func triggerShake() {
        mode = .browse   // shake results live in Browse
        shakeCount += 1
        Task { await runShake() }
    }

    func runShake() async {
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

    // Pull-to-refresh reloads whatever the user is looking at: an active search re-runs, Browse
    // force-refetches today's charts (bypassing the day cache), For You recomputes in place.
    // (@Sendable refreshable closure calls this MainActor func — never touch services inline.)
    func pullRefresh() async {
        if mode == .forYou {
            await recs.refresh(followedCategories: followedCategories)
        } else if isSearching {
            await runSearch(query)
        } else {
            await clientBox.loadTrendingIfNeeded(force: true)
        }
    }

    func runSearch(_ term: String) async {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { results = []; searchFailed = false; return }
        try? await Task.sleep(for: .milliseconds(300))   // debounce
        guard t == query.trimmingCharacters(in: .whitespaces) else { return }
        searching = true; searchFailed = false
        defer { searching = false }
        do {
            results = try await clientBox.client.search(term: t)
            if !results.isEmpty { recs.recordSearch(t) }   // an interest signal for future recs
        } catch {
            results = []; searchFailed = true
        }
    }
}
