//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var appSettings = AppSettings()
    @State private var subscriptions: SubscriptionService
    @State private var clientBox = ITunesSearchClientBox(client: ITunesSearchClient())
    @State private var playback: PlaybackManager
    @State private var downloads: DownloadManager
    @State private var refresh: FeedRefreshService
    @State private var transcripts: TranscriptService
    @State private var clips: ClipService
    @State private var searchIndexBox: SearchIndexBox
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
            let pm = PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext)
            _playback = State(initialValue: pm)
            let engine: AudioTranscribing? = {
                if #available(iOS 26, *) { return SpeechTranscriberEngine() } else { return nil }
            }()
            let index = try? SearchIndex(path: SearchIndex.defaultFileURL().path)
            let searchBox = SearchIndexBox(index: index)
            _searchIndexBox = State(initialValue: searchBox)
            _transcripts = State(initialValue: TranscriptService(
                modelContext: c.mainContext, engine: engine,
                localURL: { pm.localURL(for: $0) },
                index: index))
            UITestSeed.seed(context: c.mainContext)
            if let index, (try? index.isEmpty()) == true {
                let cues = (try? c.mainContext.fetch(FetchDescriptor<TranscriptCue>())) ?? []
                for cue in cues {
                    guard let guid = cue.transcript?.episode?.guid else { continue }
                    try? index.upsert(SearchDoc(kind: "cue", episodeGuid: guid,
                                                startTime: cue.startTime, body: cue.text))
                }
                let clips = (try? c.mainContext.fetch(FetchDescriptor<Clip>())) ?? []
                for clip in clips {
                    guard let guid = clip.episode?.guid else { continue }
                    let body = [clip.text, clip.note].compactMap { $0 }.joined(separator: " ")
                    try? index.upsert(SearchDoc(kind: "clip", episodeGuid: guid,
                                                startTime: clip.startTime, body: body))
                }
            }
            let cs = ClipService(modelContext: c.mainContext, index: index)
            _clips = State(initialValue: cs)
            pm.onCaptureRequested = { [weak pm] in
                guard let pm, let ep = pm.currentEpisode else { return }
                cs.quickClip(episode: ep, at: pm.positionSeconds)
                pm.showCaptureToast("Clipped last \(Int(ClipService.quickClipWindow))s")
            }
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
                .environment(appSettings)
                .environment(subscriptions)
                .environment(clientBox)
                .environment(playback)
                .environment(downloads)
                .environment(transcripts)
                .environment(clips)
                .environment(searchIndexBox)
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
