//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var subscriptions: SubscriptionService
    @State private var clientBox = ITunesSearchClientBox(client: ITunesSearchClient())
    @State private var playback: PlaybackManager
    @State private var downloads: DownloadManager
    @State private var refresh: FeedRefreshService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            let subs = SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient())
            let dm = DownloadManager(persistence: PersistenceActor(modelContainer: c))
            _subscriptions = State(initialValue: subs)
            _downloads = State(initialValue: dm)
            _playback = State(initialValue:
                PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext))
            let rs = FeedRefreshService(modelContext: c.mainContext, subscriptions: subs, downloads: dm)
            rs.registerBackgroundTask()
            _refresh = State(initialValue: rs)
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .environment(subscriptions)
                .environment(clientBox)
                .environment(playback)
                .environment(downloads)
                .preferredColorScheme(theme.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { [refresh] in await refresh.refreshAll() }
                    } else if phase == .background {
                        refresh.scheduleBackgroundRefresh()
                    }
                }
        }
        .modelContainer(container)
    }
}
