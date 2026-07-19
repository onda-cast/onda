//  SmartQueueTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class SmartQueueTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func episode(in ctx: ModelContext, guid: String, daysAgo: Double, duration: TimeInterval,
                         played: Bool = false, downloaded: Bool = false) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid).xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: guid, title: guid, publishDate: Date.now.addingTimeInterval(-daysAgo * 86400),
                         duration: duration, audioURL: URL(string: "https://ex.com/\(guid).mp3")!,
                         notes: "", played: played)
        ep.podcast = pod; pod.episodes.append(ep)
        if downloaded {
            let df = DownloadedFile(localFileName: "\(guid).mp3", fileSizeBytes: 100, downloadedAt: .now)
            df.episode = ep; ep.downloadedFile = df; ctx.insert(df)
        }
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_unplayed_excludesPlayed_newestFirst() throws {
        let c = try ctx()
        let old = episode(in: c, guid: "old", daysAgo: 10, duration: 100)
        let new = episode(in: c, guid: "new", daysAgo: 1, duration: 100)
        let done = episode(in: c, guid: "done", daysAgo: 0.5, duration: 100, played: true)
        let result = SmartQueue.unplayed.apply(to: [old, new, done])
        XCTAssertEqual(result.map(\.guid), ["new", "old"])
    }

    func test_downloaded_allDownloads_playedIncluded_matchingInShowFilter() throws {
        let c = try ctx()
        let a = episode(in: c, guid: "a", daysAgo: 1, duration: 100, downloaded: true)
        let b = episode(in: c, guid: "b", daysAgo: 2, duration: 100, downloaded: false)
        let playedDownloaded = episode(in: c, guid: "pd", daysAgo: 0, duration: 100, played: true, downloaded: true)
        let result = SmartQueue.downloaded.apply(to: [a, b, playedDownloaded])
        XCTAssertEqual(result.map(\.guid), ["pd", "a"],
                       "Downloaded means every download — same as EpisodeFilter.downloaded in a show")
    }

    func test_recentlyAdded_last7Days() throws {
        let c = try ctx()
        let recent = episode(in: c, guid: "recent", daysAgo: 3, duration: 100)
        let old = episode(in: c, guid: "old", daysAgo: 30, duration: 100)
        let result = SmartQueue.recentlyAdded.apply(to: [recent, old])
        XCTAssertEqual(result.map(\.guid), ["recent"])
    }

    func test_shortestFirst_sortsByDuration_excludesPlayed() throws {
        let c = try ctx()
        let long = episode(in: c, guid: "long", daysAgo: 1, duration: 3600)
        let short = episode(in: c, guid: "short", daysAgo: 1, duration: 600)
        let playedShort = episode(in: c, guid: "ps", daysAgo: 1, duration: 100, played: true)
        let result = SmartQueue.shortestFirst.apply(to: [long, short, playedShort])
        XCTAssertEqual(result.map(\.guid), ["short", "long"])
    }

    func test_unplayed_excludesArchived() throws {
        let c = try ctx()
        let live = episode(in: c, guid: "live", daysAgo: 1, duration: 100)
        let archived = episode(in: c, guid: "archived", daysAgo: 0.5, duration: 100)
        archived.isArchived = true
        let result = SmartQueue.unplayed.apply(to: [live, archived])
        XCTAssertEqual(result.map(\.guid), ["live"])
    }

    func test_hasMatches_mirrorsApplyEmptiness() throws {
        let c = try ctx()
        let played = episode(in: c, guid: "p", daysAgo: 1, duration: 100, played: true)
        XCTAssertFalse(SmartQueue.unplayed.hasMatches(in: [played]))
        XCTAssertFalse(SmartQueue.downloaded.hasMatches(in: [played]),
                       "played but never downloaded — still no match")
        XCTAssertFalse(SmartQueue.shortestFirst.hasMatches(in: [played]))
        XCTAssertTrue(SmartQueue.recentlyAdded.hasMatches(in: [played]))

        let fresh = episode(in: c, guid: "f", daysAgo: 1, duration: 100, downloaded: true)
        XCTAssertTrue(SmartQueue.unplayed.hasMatches(in: [played, fresh]))
        XCTAssertTrue(SmartQueue.downloaded.hasMatches(in: [played, fresh]))
        XCTAssertTrue(SmartQueue.shortestFirst.hasMatches(in: [played, fresh]))
    }

    func test_hasMatches_excludesArchived() throws {
        let c = try ctx()
        let archived = episode(in: c, guid: "a", daysAgo: 1, duration: 100, downloaded: true)
        archived.isArchived = true
        XCTAssertFalse(SmartQueue.unplayed.hasMatches(in: [archived]))
        XCTAssertFalse(SmartQueue.downloaded.hasMatches(in: [archived]))
        XCTAssertFalse(SmartQueue.recentlyAdded.hasMatches(in: [archived]))
        XCTAssertFalse(SmartQueue.shortestFirst.hasMatches(in: [archived]))
    }
}
