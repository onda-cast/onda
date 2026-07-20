//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var appSettings: AppSettings
    @State private var subscriptions: SubscriptionService
    @State private var clientBox = ITunesSearchClientBox(client: ITunesSearchClient())
    @State private var playback: PlaybackManager
    @State private var downloads: DownloadManager
    @State private var refresh: FeedRefreshService
    @State private var hiddenShows: HiddenShows
    @State private var transcripts: TranscriptService
    @State private var retention: EpisodeRetentionService
    @State private var chapterGen: ChapterGenerationService
    @State private var clips: ClipService
    @State private var searchIndexBox: SearchIndexBox
    @State private var recommendations: RecommendationService
    @State private var articles: ArticleConversionService
    @State private var books: BookMentionService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            let tokenStore = PrivateFeedTokenStore()
            PrivateFeedTokenMigration.run(context: c.mainContext, tokenStore: tokenStore)
            let settings = AppSettings()
            _appSettings = State(initialValue: settings)
            let hidden = HiddenShows()
            _hiddenShows = State(initialValue: hidden)
            let subs = SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient(),
                                           tokenStore: tokenStore)
            let dm = DownloadManager(persistence: PersistenceActor(modelContainer: c))
            _subscriptions = State(initialValue: subs)
            _downloads = State(initialValue: dm)
            let pm = PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext,
                                     appSettings: settings)
            _playback = State(initialValue: pm)
            let engine = OndaApp.makeTranscribingEngine()
            let index = try? SearchIndex(path: SearchIndex.defaultFileURL().path)
            _searchIndexBox = State(initialValue: SearchIndexBox(index: index))
            let ts = TranscriptService(
                modelContext: c.mainContext, engine: engine,
                localURL: { pm.localURL(for: $0) },
                index: index)
            _transcripts = State(initialValue: ts)
            let ret = OndaApp.makeRetentionService(context: c.mainContext, settings: settings, dm: dm, pm: pm)
            _retention = State(initialValue: ret)
            pm.retention = ret
            OndaApp.wireRetention(subs: subs, dm: dm, ret: ret, ts: ts, context: c.mainContext)
            _chapterGen = State(initialValue: OndaApp.makeChapterService(context: c.mainContext))
            UITestSeed.seed(context: c.mainContext)
            UITestScaleSeed.seed(context: c.mainContext)
            OndaApp.seedSearchIndexIfEmpty(index, context: c.mainContext)
            let cs = ClipService(modelContext: c.mainContext, index: index)
            _clips = State(initialValue: cs)
            OndaApp.wirePlayback(pm: pm, dm: dm, cs: cs, settings: settings)
            _refresh = State(initialValue: OndaApp.makeRefreshService(
                context: c.mainContext, subs: subs, dm: dm, settings: settings, ret: ret))
            _recommendations = State(initialValue: RecommendationService(
                modelContext: c.mainContext, client: ITunesSearchClient(), feeds: RSSFeedClient(),
                hidden: hidden))
            let articlesService = OndaApp.makeArticleService(context: c.mainContext, ts: ts)
            articlesService.registerBackgroundTask()
            _articles = State(initialValue: articlesService)
            _books = State(initialValue: OndaApp.makeBookService(context: c.mainContext))
            pm.restoreLastEpisode()   // cold-launch: bring back the last episode (paused) into the mini-player
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    private static func wirePlayback(pm: PlaybackManager, dm: DownloadManager,
                                     cs: ClipService, settings: AppSettings) {
        pm.ensureDownloaded = { [weak dm] in dm?.download($0) }
        dm.cellularAllowed = { !settings.wifiOnlyDownloads }
        pm.onCaptureRequested = { [weak pm] in
            guard let pm, let ep = pm.currentEpisode else { return }
            let clip = cs.quickClip(episode: ep, at: pm.positionSeconds)
            pm.lastQuickClip = clip
            pm.showCaptureToast("Clipped last \(Int(ClipService.quickClipWindow))s — tap to review")
        }
    }

    private static func wireRetention(subs: SubscriptionService, dm: DownloadManager,
                                      ret: EpisodeRetentionService, ts: TranscriptService,
                                      context: ModelContext) {
        // One-time normalization of pre-override ShowSettings rows (no-op after first launch).
        ShowSettingsMigrator.normalizeAll(in: context)
        subs.retention = ret
        subs.deleteDownload = { [weak dm] in dm?.delete($0) }
        subs.downloadEpisode = { [weak dm] in dm?.download($0) }
        dm.onDownloadCompleted = { guid in
            OndaApp.autoTranscribeIfEnabled(guid: guid, context: context,
                                            retention: ret, transcripts: ts)
        }
    }

    private static func makeArticleService(context: ModelContext, ts: TranscriptService) -> ArticleConversionService {
        let extractor = ArticleExtractor()
        return ArticleConversionService(
            modelContext: context,
            extract: { try await extractor.extract(from: $0) },
            renderer: ArticleSpeechRenderer(),
            persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") })
    }

    private static func makeChapterGenerator() -> ChapterGenerating? {
        if #available(iOS 26, *), FoundationModelsChapterGenerator.isAvailable {
            return FoundationModelsChapterGenerator()
        }
        return nil
    }

    private static func makeBookExtractor() -> BookExtracting? {
        if #available(iOS 26, *), FoundationModelsBookExtractor.isAvailable {
            return FoundationModelsBookExtractor()
        }
        return nil
    }

    private static func makeBookService(context: ModelContext) -> BookMentionService {
        BookMentionService(modelContext: context, llm: makeBookExtractor())
    }

    private static func makeRefreshService(context: ModelContext, subs: SubscriptionService,
                                           dm: DownloadManager, settings: AppSettings,
                                           ret: EpisodeRetentionService) -> FeedRefreshService {
        let rs = FeedRefreshService(modelContext: context, subscriptions: subs,
                                    downloads: dm, appSettings: settings)
        rs.retention = ret
        rs.registerBackgroundTask()
        return rs
    }

    private static func makeTranscribingEngine() -> AudioTranscribing? {
        if #available(iOS 26, *) { return SpeechTranscriberEngine() } else { return nil }
    }

    private static func makeRetentionService(context: ModelContext, settings: AppSettings,
                                             dm: DownloadManager, pm: PlaybackManager) -> EpisodeRetentionService {
        EpisodeRetentionService(
            modelContext: context, appSettings: settings,
            deleteDownload: { [weak dm] in dm?.delete($0) },
            isCurrentlyPlaying: { [weak pm] ep in pm?.currentEpisode?.guid == ep.guid })
    }

    private static func makeChapterService(context: ModelContext) -> ChapterGenerationService {
        ChapterGenerationService(
            modelContext: context, generator: makeChapterGenerator(),
            hasTranscript: { ep in !(ep.transcript?.cues.isEmpty ?? true) },
            transcriptText: { ep in
                let cues = ep.transcript?.cues.sorted { $0.startTime < $1.startTime } ?? []
                let joined = cues.map(\.text).joined(separator: " ")
                return joined.isEmpty ? nil : joined
            })
    }

    /// Auto-transcription after a download completes: only for episodes with no published
    /// transcript, only when the on-device engine exists, and only when Speech authorization
    /// was ALREADY granted — never prompt from a background context.
    private static func autoTranscribeIfEnabled(guid: String, context: ModelContext,
                                                retention: EpisodeRetentionService,
                                                transcripts: TranscriptService) {
        let d = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        guard let ep = try? context.fetch(d).first, let podcast = ep.podcast,
              retention.resolvedAutoTranscribe(for: podcast),
              ep.transcript == nil, ep.transcriptURL == nil,
              transcripts.hasEngine, TranscriptService.speechAuthorizationGranted else { return }
        Task { _ = await transcripts.transcript(for: ep) }
    }

    /// Populates FTS5 from existing SwiftData rows on first launch after adding search —
    /// a no-op once the index has any documents (kept out of init to keep it under the
    /// function-body-length lint budget).
    private static func seedSearchIndexIfEmpty(_ index: SearchIndex?, context: ModelContext) {
        guard let index, (try? index.isEmpty()) == true else { return }
        let cues = (try? context.fetch(FetchDescriptor<TranscriptCue>())) ?? []
        for cue in cues {
            guard let guid = cue.transcript?.episode?.guid else { continue }
            try? index.upsert(SearchDoc(kind: "cue", episodeGuid: guid,
                                        startTime: cue.startTime, body: cue.text))
        }
        let clips = (try? context.fetch(FetchDescriptor<Clip>())) ?? []
        for clip in clips {
            guard let guid = clip.episode?.guid else { continue }
            let body = [clip.text, clip.note].compactMap { $0 }.joined(separator: " ")
            try? index.upsert(SearchDoc(kind: "clip", episodeGuid: guid,
                                        startTime: clip.startTime, body: body))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(SystemSchemeBridge(theme: theme))
                .environment(theme)
                .environment(appSettings)
                .environment(subscriptions)
                .environment(clientBox)
                .environment(playback)
                .environment(downloads)
                .environment(transcripts)
                .environment(retention)
                .environment(chapterGen)
                .environment(clips)
                .environment(searchIndexBox)
                .environment(recommendations)
                .environment(articles)
                .environment(books)
                .environment(hiddenShows)
                .environment(refresh)
                .preferredColorScheme(theme.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        playback.handleAppBecameActive()
                        articles.resumePersisted()
                        Task { [refresh] in await refresh.refreshAll() }
                    } else if phase == .background {
                        articles.scheduleBackgroundProcessing()
                        refresh.scheduleBackgroundRefresh()
                    }
                }
        }
        .modelContainer(container)
    }
}

/// Feeds the device's live light/dark scheme into AppTheme so `.system` mode resolves
/// colours correctly and updates when the user flips their device appearance.
private struct SystemSchemeBridge: ViewModifier {
    let theme: AppTheme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .onAppear { theme.systemIsDark = colorScheme == .dark }
            .onChange(of: colorScheme) { _, new in theme.systemIsDark = new == .dark }
    }
}
