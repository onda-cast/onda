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

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            _subscriptions = State(initialValue:
                SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient()))
            _playback = State(initialValue:
                PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext))
            _downloads = State(initialValue:
                DownloadManager(persistence: PersistenceActor(modelContainer: c)))
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
        }
        .modelContainer(container)
    }
}
