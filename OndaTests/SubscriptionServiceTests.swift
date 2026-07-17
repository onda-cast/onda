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
}
