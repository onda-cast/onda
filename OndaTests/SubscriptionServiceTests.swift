//  SubscriptionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubFeeds: FeedFetching {
    var feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed { feed }
}

@MainActor
final class SubscriptionServiceTests: XCTestCase {
    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func dto() -> PodcastDTO {
        PodcastDTO(collectionId: 1, collectionName: "The Signal", artistName: "Ex",
                   feedUrl: URL(string: "https://ex.com/f.xml"),
                   artworkUrl600: URL(string: "https://ex.com/a.jpg"), primaryGenreName: "Technology")
    }

    private func feed(_ guids: [String]) -> ParsedFeed {
        ParsedFeed(title: "The Signal", author: "Ex", artworkURL: nil, category: "Technology",
                   episodes: guids.map {
                       ParsedEpisode(guid: $0, title: "T-\($0)", publishDate: .now, duration: 100,
                                     audioURL: URL(string: "https://ex.com/\($0).mp3")!,
                                     notes: "", chaptersURL: nil)
                   })
    }

    func test_subscribe_autoDownloadsNewestEpisode() async throws {
        let ctx = try context()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = ParsedFeed(title: "The Signal", author: "Ex", artworkURL: nil, category: "Tech",
                              episodes: [
                                ParsedEpisode(guid: "old", title: "Old", publishDate: base,
                                              duration: 100, audioURL: URL(string: "https://ex.com/old.mp3")!,
                                              notes: "", chaptersURL: nil),
                                ParsedEpisode(guid: "new", title: "New", publishDate: base.addingTimeInterval(86_400),
                                              duration: 100, audioURL: URL(string: "https://ex.com/new.mp3")!,
                                              notes: "", chaptersURL: nil)
                              ])
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed))
        var downloaded: [String] = []
        svc.downloadEpisode = { downloaded.append($0.guid) }
        _ = try await svc.subscribe(to: dto())
        XCTAssertEqual(downloaded, ["new"], "only the newest episode auto-downloads on subscribe")
    }

    func test_subscribe_createsPodcastSettingsAndEpisodes() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertTrue(pod.isSubscribed)
        XCTAssertNotNil(pod.settings)
        XCTAssertEqual(pod.episodes.count, 2)
    }

    func test_refresh_addsOnlyNewEpisodes() async throws {
        let ctx = try context()
        var svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertEqual(pod.episodes.count, 1)

        svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b", "c"])))
        try await svc.refreshEpisodes(for: pod)
        XCTAssertEqual(pod.episodes.count, 3, "existing guid 'a' not duplicated")
    }

    func test_markPlayed_togglesAndClearsPosition() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        let ep = pod.episodes[0]
        ep.playbackPosition = 500
        svc.setPlayed(ep, true)
        XCTAssertTrue(ep.played)
        XCTAssertEqual(ep.playbackPosition, 0, "marking played clears resume position")
        svc.setPlayed(ep, false)
        XCTAssertFalse(ep.played)
    }

    func test_archiveEpisode_keepTranscript_hidesEpisodeKeepsTranscriptAndClips() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        let ep = pod.episodes[0]
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        let cue = TranscriptCue(startTime: 0, endTime: 1, text: "x", speaker: nil)
        cue.transcript = tr; tr.cues.append(cue)
        let clip = Clip(startTime: 0, endTime: 1, text: "x", note: nil, createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip)
        ctx.insert(tr); ctx.insert(cue); ctx.insert(clip); try ctx.save()

        svc.archiveEpisode(ep, keepTranscript: true)
        XCTAssertTrue(ep.isArchived)
        XCTAssertNotNil(ep.transcript, "transcript kept per setting")
        XCTAssertEqual(ep.clips.count, 1, "clips always survive")

        // Refresh must not resurrect the archived episode into visible lists.
        try await svc.refreshEpisodes(for: pod)
        XCTAssertTrue(ep.isArchived)
    }

    func test_archiveEpisode_dropTranscript_removesTranscript() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        let ep = pod.episodes[0]
        let tr = Transcript(source: "published", language: "en"); tr.episode = ep; ep.transcript = tr
        ctx.insert(tr); try ctx.save()

        svc.archiveEpisode(ep, keepTranscript: false)
        XCTAssertTrue(ep.isArchived)
        XCTAssertNil(ep.transcript)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transcript>()).count, 0)
    }

    func test_subscribeTwice_doesNotDuplicatePodcast() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        _ = try await svc.subscribe(to: dto())
        _ = try await svc.subscribe(to: dto())
        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
    }

    func test_unsubscribe_localShow_deletesEpisodesAndArticleSources_keepsPodcastAndSettings() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        var deleted: [String] = []
        svc.deleteDownload = { deleted.append($0.guid) }
        let pod = Podcast(feedURL: URL(string: "onda-local:articles")!, title: "Articles",
                          author: "You", artworkURL: nil, category: "Articles", itunesId: nil,
                          isSubscribed: true)
        pod.isLocal = true
        let settings = ShowSettings.makeDefault(); settings.podcast = pod; pod.settings = settings
        ctx.insert(pod); ctx.insert(settings)

        let ep = Episode(guid: "art-1", title: "Article One", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/art-1.m4a")!, notes: "")
        ep.sourceType = "article"
        ep.podcast = pod; pod.episodes.append(ep)
        let source = ArticleSource(sourceURL: URL(string: "https://example.com/article")!,
                                   siteName: "Example", addedAt: .now)
        source.episode = ep; ep.articleSource = source
        let file = DownloadedFile(localFileName: "art-1.m4a", fileSizeBytes: 100, downloadedAt: .now)
        file.episode = ep; ep.downloadedFile = file
        let tr = Transcript(source: "ondevice", language: "en"); tr.episode = ep; ep.transcript = tr
        ctx.insert(ep); ctx.insert(source); ctx.insert(file); ctx.insert(tr)
        try ctx.save()

        svc.unsubscribe(pod)

        XCTAssertEqual(deleted, ["art-1"], "download-freeing closure was invoked before the row was deleted")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 0, "episode row is gone, not just archived")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ArticleSource>()).count, 0,
                       "ArticleSource cascades away with its Episode")
        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1, "the Podcast row survives so re-adding an article finds it again")
        XCTAssertFalse(pods[0].isSubscribed)
        XCTAssertNotNil(pods[0].settings, "ShowSettings (voice preference) survives")
    }

    func test_unsubscribe_nonLocalShow_episodesSurvive() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        svc.deleteDownload = { _ in }
        let pod = try await svc.subscribe(to: dto())
        svc.unsubscribe(pod)
        XCTAssertFalse(pod.isSubscribed)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1,
                       "unsubscribing a normal feed show only frees downloads — episodes stay so " +
                       "resubscribing doesn't need to re-fetch history")
    }

    func test_refreshEpisodes_localShow_neverTouchesTheFeed() async throws {
        struct ThrowingFeeds: FeedFetching {
            func fetchFeed(_ url: URL) async throws -> ParsedFeed {
                XCTFail("local shows must not be fetched")
                throw NSError(domain: "test", code: 1)
            }
        }
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: ThrowingFeeds())
        let pod = Podcast(feedURL: URL(string: "onda-local:articles")!, title: "Articles",
                          author: "You", artworkURL: nil, category: "Articles", itunesId: nil,
                          isSubscribed: true)
        pod.isLocal = true
        ctx.insert(pod)
        try await svc.refreshEpisodes(for: pod)   // must be a silent no-op
    }
}
