//  DiscoverView.swift
import SwiftUI
import SwiftData

// Row tap → show preview. Identifiable wrapper because PodcastDTO itself isn't Identifiable.
private struct PreviewTarget: Identifiable {
    let id = UUID()
    let dto: PodcastDTO
}

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(ITunesSearchClientBox.self) private var clientBox
    @Environment(RecommendationService.self) private var recs
    @Environment(PlaybackManager.self) private var playback
    @Environment(HiddenShows.self) private var hidden
    @Environment(HiddenCategories.self) private var hiddenCategories
    @Query(filter: #Predicate<Podcast> { $0.isSubscribed }) private var subs: [Podcast]

    @State private var query = ""
    @State private var results: [PodcastDTO] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var shake: ShakeState?
    @State private var shakeCount = 0
    @State private var dealID = 0   // bumps when shake results land; replays the deal-in animation
    // Locked from the moment a shake/shuffle is triggered until the fetch AND the deal-in
    // animation both finish — a second trigger mid-animation (double-tap, or shake right after
    // tapping) would restart the deal-in on cards still animating in, a visible glitch.
    @State private var isShuffling = false
    @State private var mode: DiscoverMode = .browse
    @State private var toast: String?
    @State private var unfollowTarget: PodcastDTO?
    @State private var showAddByURL = false
    @State private var undoToastTask: Task<Void, Never>?
    @State private var showUndoToast = false
    @State private var hideToastTask: Task<Void, Never>?
    @State private var showHideToast = false
    // Category chips are real filters: own result set, never writes into the visible search text.
    @State private var selectedCategory: String?
    @State private var categoryResults: [PodcastDTO] = []
    @State private var categoryFailed = false
    @FocusState private var searchFocused: Bool
    @State private var previewTarget: PreviewTarget?

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

    private static let allChipCategories = ["Technology", "Comedy", "News", "Business",
                                             "Health & Fitness", "Science"]
    private var categories: [String] {
        Self.allChipCategories.filter { !hiddenCategories.isHidden(category: $0) }
    }
    private var subscribedFeeds: Set<URL> { Set(subs.map(\.feedURL)) }
    private var followedCategories: [String] {
        Array(Set(subs.map(\.category))).sorted()
            .filter { !hiddenCategories.isHidden(category: $0) }
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
                // Row tap opens a preview; the inner Follow Button still wins its own taps.
                let row = TrendingRow(dto: dto, isSubscribed: isSubscribed(dto)) { toggleFollow(dto) }
                    .contentShape(Rectangle()).onTapGesture { previewTarget = PreviewTarget(dto: dto) }
                    .accessibilityHint("Opens a preview of this show")
                    .swipeToHide { hideShow(dto) }
                    .contextMenu {
                        // A11y/discoverable path to the same action the swipe performs.
                        Button(role: .destructive) { hideShow(dto) } label: {
                            Label("Hide from Discover", systemImage: "eye.slash")
                        }
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
                        .opacity(isShuffling ? 0.5 : 1)   // visibly locked while a shuffle is in flight
                    }
                    .buttonStyle(.plain)
                    .disabled(isShuffling)
                    .accessibilityLabel("Shuffle new podcasts")
                    .accessibilityHint("Also works by shaking your phone")
                }
                .padding(.top, 56)

                SegmentedRow(options: [("Browse", DiscoverMode.browse), ("For You", .forYou)],
                             selection: mode) { mode = $0 }

                if mode == .browse { browseTab } else { forYouTab }
            }
            .padding(.horizontal, 20).padding(.bottom, BottomChrome.clearance)
        }
        .miniPlayerAutoHide(playback)
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
        // Get the mini-player out of the way of the keyboard/results while actively searching;
        // MiniPlayerAutoHide's own scroll logic and the tab-switch restore still apply otherwise.
        .onChange(of: searchFocused) { _, focused in
            playback.miniPlayerHidden = focused
            playback.tabBarHidden = focused
        }
        // Belt: if Discover unloads while search is focused, never strand the chrome off-screen.
        .onDisappear { playback.tabBarHidden = false }
        .sheet(isPresented: $showAddByURL) {
            AddByURLSheet().presentationDetents([.medium, .large])
        }
        .sheet(item: $previewTarget) { target in
            ShowPreviewSheet(dto: target.dto, isSubscribed: isSubscribed(target.dto),
                             onToggle: { handlePreviewToggle(target) })
                .presentationDetents([.medium, .large])
        }
        .background(theme.color(.bg))
        .task { await clientBox.loadTrendingIfNeeded() }
        .task { await recs.refreshIfStale(followedCategories: followedCategories) }
        .onChange(of: query) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty {
                shake = nil
                selectedCategory = nil; categoryResults = []; categoryFailed = false   // typed search supersedes a category
            }
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
                BrutalToast(text: toast)
                    .padding(.bottom, BottomChrome.clearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showUndoToast, let rec = recs.lastDismissed {
                UndoToastButton(
                    text: "Not interested: \(rec.dto.collectionName) \u{2014} UNDO",
                    accessibility: "Dismissed \(rec.dto.collectionName). Double-tap to undo.") {
                        undoToastTask?.cancel()
                        withAnimation { showUndoToast = false }
                        recs.undoDismiss()
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if showHideToast, let hiddenShow = hidden.lastHidden {
                UndoToastButton(
                    text: "Hidden: \(hiddenShow.title) \u{2014} UNDO",
                    accessibility: "Hid \(hiddenShow.title) from Discover. Double-tap to undo.") {
                        hideToastTask?.cancel()
                        withAnimation { showHideToast = false }
                        hidden.undoHide()
                    }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    let selected = selectedCategory == cat
                    Button { selectCategory(selected ? nil : cat) } label: {
                        HStack(spacing: 4) {
                            if selected {
                                Image(systemName: "checkmark").scaledFont(10, weight: .black)
                            }
                            Text(cat).brutalHeader(size: 11.5)
                        }
                        .foregroundStyle(selected ? .white : theme.color(.text))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(selected ? theme.color(.accentStrong) : theme.color(.bgElevated))
                        .brutalBorder(width: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }

    private var listItems: [PodcastDTO] {
        let items: [PodcastDTO]
        var filterHiddenCategories = false
        if let picks = shake?.picks {
            items = picks; filterHiddenCategories = true
        } else if !results.isEmpty {
            items = results
        } else if selectedCategory != nil {
            items = categoryResults
        } else {
            items = trending; filterHiddenCategories = true
        }
        return items.filter {
            Self.isVisible($0, showHidden: hidden.isHidden, categoryHidden: hiddenCategories.isHidden,
                           filterCategories: filterHiddenCategories)
        }
    }

    /// Whether a suggestion should be shown, given both hide stores and whether this item's
    /// source is subject to category filtering (Trending/Shake are; typed search and an explicit
    /// category-chip pick are not — hiding a category never touches an explicit ask). Exposed as
    /// `internal` (not `private`) so it's directly unit-testable without a SwiftUI environment.
    static func isVisible(_ dto: PodcastDTO, showHidden: (PodcastDTO) -> Bool,
                          categoryHidden: (PodcastDTO) -> Bool, filterCategories: Bool) -> Bool {
        !showHidden(dto) && (!filterCategories || !categoryHidden(dto))
    }

    @ViewBuilder private var listHeader: some View {
        if let shake {
            shakeHeader(shake)
                .id(dealID)
                .transition(.asymmetric(
                    insertion: .scale(scale: 1.35, anchor: .leading).combined(with: .opacity),
                    removal: .opacity))
        } else {
            Text(!results.isEmpty ? "Results"
                 : selectedCategory.map { $0.uppercased() } ?? "Trending Today")
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
                    .background(theme.color(.accentStrong)).brutalBorder(width: 2)
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity).padding(.top, 36)
    }
}

// MARK: - Follow / toast
extension DiscoverView {
    // Preview sheet's follow toggle. For an already-subscribed show, the unfollow confirmation
    // lives on the view UNDER this sheet — dismiss first, then present (400ms: same sheet
    // hand-off beat as the transcript-jump flow) instead of routing through toggleFollow directly.
    fileprivate func handlePreviewToggle(_ target: PreviewTarget) {
        if isSubscribed(target.dto) {
            previewTarget = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                unfollowTarget = target.dto
            }
        } else {
            toggleFollow(target.dto)
        }
    }

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

// MARK: - Browse status + For You sub-tab
extension DiscoverView {
    // Distinguish loading / error / genuinely-empty so a network failure never looks like "no results".
    @ViewBuilder private var browseStatus: some View {
        if isSearching {
            if searchFailed {
                errorRetry("Search failed — check your connection") { Task { await runSearch(query) } }
            } else if !searching && results.isEmpty {
                statusNote("No results for “\(query)”")
            }
        } else if let cat = selectedCategory, categoryResults.isEmpty {
            if categoryFailed {
                errorRetry("Couldn't load \(cat) — check your connection") { selectCategory(cat) }
            } else {
                loadingRow("Loading \(cat)…")
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

    /// Swipe/context "hide from Discover": adds to the Settings-managed hidden list and
    /// offers a 5s undo (same shape as the recommendation "not interested" toast).
    func hideShow(_ dto: PodcastDTO) {
        hidden.hide(dto)
        withAnimation { showHideToast = true }
        hideToastTask?.cancel()
        hideToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation { showHideToast = false } }
        }
    }

    func dismissRecommendation(_ rec: Recommendation) {
        recs.dismiss(rec)
        withAnimation { showUndoToast = true }
        undoToastTask?.cancel()
        undoToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation { showUndoToast = false } }
        }
    }

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
                    .frame(width: 44, height: 44)
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
            ForEach(recs.recommendations.filter { !hidden.isHidden($0.dto) && !hiddenCategories.isHidden($0.dto) }) { rec in
                RecommendationRow(rec: rec, isSubscribed: isSubscribed(rec.dto),
                                  onFollow: { toggleFollow(rec.dto) },
                                  onPreview: { previewTarget = PreviewTarget(dto: rec.dto) },
                                  onDismiss: { dismissRecommendation(rec) },
                                  onHide: { hideShow(rec.dto) })
            }
        }
    }
}

// MARK: - Data loading & shake
extension DiscoverView {
    // Shared entry point for the shake gesture and the visible Shuffle button. Locked out (button
    // disabled, physical shake ignored) while a previous shuffle is still fetching or dealing in —
    // a re-trigger mid-animation would restart the deal-in on cards still in flight.
    func triggerShake() {
        guard !isShuffling else { return }
        isShuffling = true
        mode = .browse   // shake results live in Browse
        shakeCount += 1
        Task { await runShake() }
    }

    func runShake() async {
        var rng = SystemRandomNumberGenerator()
        let result = await shakeSuggestions(
            followedCategories: followedCategories,
            fallbackCategories: categories,
            subscribedFeeds: subscribedFeeds,
            hiddenCategories: hiddenCategories.hidden,
            using: clientBox.client,
            rng: &rng)
        // Nothing new to show → say so; the wave/haptic already fired, so silence here
        // reads as a broken button. No deal-in animation follows, so unlock immediately.
        guard !result.picks.isEmpty else {
            showToast("Nothing new right now \u{2014} try again later")
            isShuffling = false
            return
        }
        let title = Self.shakeTitles.randomElement() ?? "Shaken for you"
        withAnimation(.spring(duration: 0.35, bounce: 0.35)) {
            shake = ShakeState(picks: result.picks, categories: result.categories,
                               usedFallback: result.usedFallback, title: title)
            dealID += 1   // re-deals the cards and fires the landing haptic
        }
        // DealtCard staggers each card's own deal-in animation (up to 12 deep, 0.05s apart,
        // 0.38s spring each — see DealtCard.swift) independently of this withAnimation block, so
        // there's no single completion callback to hook. Unlock once the LAST card's animation
        // has had time to settle, with a small buffer for spring overshoot past its nominal duration.
        let lastCardDelay = Double(min(result.picks.count - 1, 12)) * 0.05
        let totalAnimationDuration = lastCardDelay + 0.38 + 0.15
        try? await Task.sleep(for: .seconds(totalAnimationDuration))
        isShuffling = false
    }

    // Content-focused browsing: scrolling down into Discover tucks the mini-player away;
    // scrolling back up (or nearing the top) brings it back. Small deltas are ignored so the
    // bar doesn't flicker on micro-drags; content minY is ≤0 and shrinks as you scroll down.
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

    /// Category chip tap: toggles a category browse with its own result set. Typing a search
    /// clears it (see onChange(of: query)); the visible query text is never modified.
    func selectCategory(_ cat: String?) {
        selectedCategory = cat
        categoryResults = []
        categoryFailed = false
        shake = nil
        guard let cat else { return }
        Task { [clientBox] in
            do {
                let found = try await clientBox.client.search(term: cat)
                // Only publish if this category is still the selected one (user may have moved on).
                if selectedCategory == cat { categoryResults = found }
            } catch {
                // Distinguish a failed fetch from "still loading" — otherwise a network error
                // leaves the category row on "Loading…" forever with no way to retry.
                if selectedCategory == cat { categoryFailed = true }
            }
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
