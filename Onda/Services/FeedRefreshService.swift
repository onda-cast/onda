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
    private var lastRefresh: Date = .distantPast
    static let minRefreshInterval: TimeInterval = 15 * 60

    init(modelContext: ModelContext, subscriptions: SubscriptionService, downloads: DownloadManager) {
        self.modelContext = modelContext
        self.subscriptions = subscriptions
        self.downloads = downloads
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
                if podcast.settings?.autoDownload == true {
                    for ep in newEpisodesAfterRefresh(for: podcast, knownGuids: known) {
                        downloads.download(ep)
                    }
                }
            } catch { continue }
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
