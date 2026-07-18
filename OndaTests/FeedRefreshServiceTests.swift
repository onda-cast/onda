//  FeedRefreshServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubFeeds: FeedFetching {
    var feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed { feed }
}

@MainActor
final class FeedRefreshServiceTests: XCTestCase {
    private struct TestEnv {
        let context: ModelContext
        let subscriptions: SubscriptionService
        let downloads: DownloadManager
        let appSettings: AppSettings
    }

    private func env(feedGuids: [String]) throws -> TestEnv {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let feed = ParsedFeed(title: "S", author: "A", artworkURL: nil, category: "Tech",
                              episodes: feedGuids.map {
                                  ParsedEpisode(guid: $0, title: $0, publishDate: .now, duration: 100,
                                                audioURL: URL(string: "https://ex.com/\($0).mp3")!,
                                                notes: "", chaptersURL: nil) })
        let subs = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed))
        let dm = DownloadManager(persistence: PersistenceActor(modelContainer: container),
                                 session: FakeURLSession())
        let suite = "FeedRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TestEnv(context: ctx, subscriptions: subs, downloads: dm,
                       appSettings: AppSettings(defaults: defaults))
    }

    private func makeService(_ testEnv: TestEnv) -> FeedRefreshService {
        FeedRefreshService(modelContext: testEnv.context, subscriptions: testEnv.subscriptions,
                           downloads: testEnv.downloads, appSettings: testEnv.appSettings)
    }

    func test_newEpisodesAfterRefresh_returnsOnlyNewGuids() throws {
        let testEnv = try env(feedGuids: ["a", "b"])
        let svc = makeService(testEnv)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        for g in ["a", "b"] {
            let ep = Episode(guid: g, title: g, publishDate: .now, duration: 100,
                             audioURL: URL(string: "https://ex.com/\(g).mp3")!, notes: "")
            ep.podcast = pod; pod.episodes.append(ep)
        }
        let newOnes = svc.newEpisodesAfterRefresh(for: pod, knownGuids: ["a"])
        XCTAssertEqual(newOnes.map(\.guid), ["b"])
    }

    func test_refreshAll_noNewEpisodes_downloadsNothing() async throws {
        let testEnv = try env(feedGuids: ["a", "b"])
        let dto = PodcastDTO(collectionId: 1, collectionName: "S", artistName: "A",
                             feedUrl: URL(string: "https://ex.com/f.xml"),
                             artworkUrl600: nil, primaryGenreName: "Tech")
        let pod = try await testEnv.subscriptions.subscribe(to: dto)     // starts with a,b
        pod.settings?.autoDownload = true
        try testEnv.context.save()
        let svc = makeService(testEnv)
        await svc.refreshAll()   // no new episodes → nothing downloads
        XCTAssertEqual(testEnv.downloads.state(for: pod.episodes.first!), DownloadState.none)
    }

    func test_refreshAll_autoDownloads_whenGlobalDefaultOn_andShowHasNoOverride() async throws {
        let testEnv = try env(feedGuids: ["a"])
        testEnv.appSettings.defaultAutoDownload = true
        // Subscribed show with no episodes yet and no per-show override (settings nil).
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        testEnv.context.insert(pod)
        try testEnv.context.save()
        let svc = makeService(testEnv)
        await svc.refreshAll()   // feed adds "a" → new episode, inherited auto-download kicks in
        let ep = try XCTUnwrap(pod.episodes.first)
        if case .downloading = testEnv.downloads.state(for: ep) {} else {
            XCTFail("expected the new episode to start downloading via the global default")
        }
    }
}
