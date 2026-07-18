//  SubscriptionServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubFeeds: FeedFetching {
    var feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed { feed }
}

private struct FailingFeeds: FeedFetching {
    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        throw NSError(domain: "test", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "not found"])
    }
}

private final class InMemoryTokenStore: PrivateFeedTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: URL] = [:]

    func store(realURL: URL, hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[hash] = realURL
    }

    func realURL(forHash hash: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        return storage[hash]
    }

    func delete(hash: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: hash)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

private struct RequireURLFeeds: FeedFetching {
    let expected: URL
    let feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        guard url == expected else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected URL: \(url)"])
        }
        return feed
    }
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

    func test_refreshEpisodes_privateFeed_resolvesRealURLFromTokenStore() async throws {
        let ctx = try context()
        let tokenStore = InMemoryTokenStore()
        let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let subscribeSvc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                               tokenStore: tokenStore)
        let pod = try await subscribeSvc.subscribeToFeedURL(realURL)

        // If refreshEpisodes fetched the placeholder URL instead of resolving the real one,
        // RequireURLFeeds throws and this call fails.
        let refreshSvc = SubscriptionService(modelContext: ctx,
                                             feeds: RequireURLFeeds(expected: realURL, feed: feed(["a", "b"])),
                                             tokenStore: tokenStore)
        try await refreshSvc.refreshEpisodes(for: pod)
        XCTAssertEqual(pod.episodes.count, 2)
    }

    func test_refreshEpisodes_privateFeed_missingToken_throws() async throws {
        let ctx = try context()
        let tokenStore = InMemoryTokenStore()
        let realURL = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                      tokenStore: tokenStore)
        let pod = try await svc.subscribeToFeedURL(realURL)
        tokenStore.removeAll()
        do {
            try await svc.refreshEpisodes(for: pod)
            XCTFail("expected throw when the Keychain token is missing")
        } catch { /* expected */ }
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

    func test_subscribeToFeedURL_createsPrivatePodcastFromChannelMetadata() async throws {
        let ctx = try context()
        let tokenStore = InMemoryTokenStore()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a", "b"])),
                                      tokenStore: tokenStore)
        let url = URL(string: "https://feeds.example.com/private.xml?token=s3cret")!
        let pod = try await svc.subscribeToFeedURL(url)
        XCTAssertTrue(pod.isPrivateFeed)
        XCTAssertTrue(pod.isSubscribed)
        XCTAssertEqual(pod.feedURL.scheme, "onda-private-feed", "feedURL is replaced with a placeholder")
        XCTAssertNotEqual(pod.feedURL, url, "the real tokenized URL must not be stored in SwiftData")
        XCTAssertEqual(try tokenStore.realURL(forHash: pod.feedURL.host!), url,
                      "the real URL is retrievable from the token store")
        XCTAssertEqual(pod.title, "The Signal", "title comes from the feed channel")
        XCTAssertEqual(pod.author, "Ex")
        XCTAssertEqual(pod.category, "Technology")
        XCTAssertNil(pod.itunesId)
        XCTAssertNotNil(pod.settings)
        XCTAssertEqual(pod.episodes.count, 2)
    }

    func test_subscribeToFeedURL_autoDownloadsNewestEpisode() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                      tokenStore: InMemoryTokenStore())
        var downloaded: [String] = []
        svc.downloadEpisode = { downloaded.append($0.guid) }
        _ = try await svc.subscribeToFeedURL(URL(string: "https://ex.com/p.xml?t=k")!)
        XCTAssertEqual(downloaded, ["a"])
    }

    func test_subscribeToFeedURL_twice_doesNotDuplicatePodcast() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])),
                                      tokenStore: InMemoryTokenStore())
        let url = URL(string: "https://ex.com/p.xml?t=k")!
        _ = try await svc.subscribeToFeedURL(url)
        let again = try await svc.subscribeToFeedURL(url)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertTrue(again.isSubscribed)
    }

    func test_subscribeToFeedURL_fetchFailure_persistsNothing() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: FailingFeeds())
        do {
            _ = try await svc.subscribeToFeedURL(URL(string: "https://ex.com/bad.xml")!)
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 0)
    }

    func test_subscribe_publicPath_isNotPrivate() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        let pod = try await svc.subscribe(to: dto())
        XCTAssertFalse(pod.isPrivateFeed)
    }

    func test_subscribeTwice_doesNotDuplicatePodcast() async throws {
        let ctx = try context()
        let svc = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed(["a"])))
        _ = try await svc.subscribe(to: dto())
        _ = try await svc.subscribe(to: dto())
        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
    }
}
