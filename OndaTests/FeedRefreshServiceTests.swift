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
        return TestEnv(context: ctx, subscriptions: subs, downloads: dm)
    }

    func test_newEpisodesAfterRefresh_returnsOnlyNewGuids() throws {
        let testEnv = try env(feedGuids: ["a", "b"])
        let svc = FeedRefreshService(modelContext: testEnv.context,
                                     subscriptions: testEnv.subscriptions, downloads: testEnv.downloads)
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
        let svc = FeedRefreshService(modelContext: testEnv.context,
                                     subscriptions: testEnv.subscriptions, downloads: testEnv.downloads)
        await svc.refreshAll()   // no new episodes → nothing downloads
        XCTAssertEqual(testEnv.downloads.state(for: pod.episodes.first!), DownloadState.none)
    }
}
