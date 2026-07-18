//  FeedRefreshService.swift
import Foundation
import SwiftData
import BackgroundTasks

@MainActor
@Observable
final class FeedRefreshService {
    nonisolated static let taskId = "com.onda.refresh"
    private let modelContext: ModelContext
    private let subscriptions: SubscriptionService
    private let downloads: DownloadManager
    private let appSettings: AppSettings
    // Wired post-init in OndaApp; the refresh cycle doubles as the periodic retention sweep
    // (catches day-based expiry, which has no event of its own).
    var retention: EpisodeRetentionService?
    private var lastRefresh: Date = .distantPast
    static let minRefreshInterval: TimeInterval = 15 * 60

    init(modelContext: ModelContext, subscriptions: SubscriptionService, downloads: DownloadManager,
         appSettings: AppSettings) {
        self.modelContext = modelContext
        self.subscriptions = subscriptions
        self.downloads = downloads
        self.appSettings = appSettings
    }

    func newEpisodesAfterRefresh(for podcast: Podcast, knownGuids: Set<String>) -> [Episode] {
        podcast.episodes.filter { !knownGuids.contains($0.guid) }
    }

    func refreshAll(force: Bool = false) async {
        // Foregrounding the app shouldn't re-parse every feed each time — throttle to 15 min.
        guard force || Date.now.timeIntervalSince(lastRefresh) > Self.minRefreshInterval else { return }
        lastRefresh = .now
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed })
        let podcasts = (try? modelContext.fetch(d)) ?? []
        for podcast in podcasts {
            let known = Set(podcast.episodes.map(\.guid))
            do {
                try await subscriptions.refreshEpisodes(for: podcast)
                if ResolvedPlaybackSettings(show: podcast.settings, app: appSettings).autoDownload {
                    for ep in newEpisodesAfterRefresh(for: podcast, knownGuids: known) {
                        downloads.download(ep)
                    }
                }
            } catch { continue }
            retention?.evictEligibleEpisodes(for: podcast)
        }
    }

    // MARK: Background task
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskId, using: nil) { task in
            let op = Task { @MainActor [weak self] in
                await self?.refreshAll()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { op.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
