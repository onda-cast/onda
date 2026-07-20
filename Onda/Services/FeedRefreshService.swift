//  FeedRefreshService.swift
import Foundation
import SwiftData
import BackgroundTasks
import os

private let refreshLog = Logger(subsystem: "com.chasegilliam.Onda", category: "feedRefresh")

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

    /// Show titles whose feed failed to refresh on the most recent `refreshAll` — reset at the
    /// start of every run. Previously a failure was silently swallowed (`catch { continue }`)
    /// with no signal anywhere; this at least makes it observable (logged now, surfaceable in
    /// UI later) instead of a feed just quietly going stale forever.
    private(set) var lastRefreshFailures: [String] = []

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

    /// Refreshes every subscribed show. Podcasts refresh concurrently (each is still a
    /// @MainActor-isolated call, so SwiftData writes stay serialized — only the network fetches
    /// actually overlap) instead of one at a time, which used to make the wall-clock cost scale
    /// linearly with subscription count.
    func refreshAll(force: Bool = false) async {
        // Foregrounding the app shouldn't re-parse every feed each time — throttle to 15 min.
        guard force || Date.now.timeIntervalSince(lastRefresh) > Self.minRefreshInterval else { return }
        lastRefresh = .now
        lastRefreshFailures = []
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed })
        let podcasts = (try? modelContext.fetch(d)) ?? []
        let tasks = podcasts.map { podcast in
            Task { @MainActor [weak self] in await self?.refreshOne(podcast) }
        }
        for task in tasks { await task.value }
    }

    private func refreshOne(_ podcast: Podcast) async {
        let known = Set(podcast.episodes.map(\.guid))
        do {
            try await subscriptions.refreshEpisodes(for: podcast)
        } catch {
            lastRefreshFailures.append(podcast.title)
            refreshLog.error("refresh failed for \(podcast.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        if ResolvedPlaybackSettings(show: podcast.settings, app: appSettings).autoDownload {
            for ep in newEpisodesAfterRefresh(for: podcast, knownGuids: known) {
                downloads.download(ep)
            }
        }
        retention?.evictEligibleEpisodes(for: podcast)
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
