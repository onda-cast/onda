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
                         played: Bool = false, downloaded: Bool = false,
                         downloadedDaysAgo: Double = 0) -> Episode {
        let pod = Podcast(feedURL: URL(string: "https://ex.com/\(guid).xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: guid, title: guid, publishDate: Date.now.addingTimeInterval(-daysAgo * 86400),
                         duration: duration, audioURL: URL(string: "https://ex.com/\(guid).mp3")!,
                         notes: "", played: played)
        ep.podcast = pod; pod.episodes.append(ep)
        if downloaded {
            let df = DownloadedFile(localFileName: "\(guid).mp3", fileSizeBytes: 100,
                                    downloadedAt: Date.now.addingTimeInterval(-downloadedDaysAgo * 86400))
            df.episode = ep; ep.downloadedFile = df; ctx.insert(df)
        }
        ctx.insert(pod); ctx.insert(ep)
        return ep
    }

    func test_unplayed_downloadedOnly_excludesPlayed_newestFirst() throws {
        let c = try ctx()
        let old = episode(in: c, guid: "old", daysAgo: 10, duration: 100, downloaded: true)
        let new = episode(in: c, guid: "new", daysAgo: 1, duration: 100, downloaded: true)
        let done = episode(in: c, guid: "done", daysAgo: 0.5, duration: 100, played: true, downloaded: true)
        let notDownloaded = episode(in: c, guid: "nd", daysAgo: 0.2, duration: 100)
        let result = SmartQueue.unplayed.apply(to: [old, new, done, notDownloaded])
        XCTAssertEqual(result.map(\.guid), ["new", "old"], "unplayed shows only downloaded, unplayed episodes")
    }

    func test_downloaded_mostRecentlyDownloadedFirst_playedIncluded() throws {
        let c = try ctx()
        // Sort key is download time, not publish date: `a` published later but downloaded earlier.
        let a = episode(in: c, guid: "a", daysAgo: 1, duration: 100, downloaded: true, downloadedDaysAgo: 5)
        let b = episode(in: c, guid: "b", daysAgo: 2, duration: 100, downloaded: false)
        let playedDownloaded = episode(in: c, guid: "pd", daysAgo: 0, duration: 100, played: true,
                                       downloaded: true, downloadedDaysAgo: 1)
        let result = SmartQueue.downloaded.apply(to: [a, b, playedDownloaded])
        XCTAssertEqual(result.map(\.guid), ["pd", "a"],
                       "Every download, played included, most recently downloaded first")
    }

    func test_recentlyAdded_downloadedOnly_last7Days() throws {
        let c = try ctx()
        let recent = episode(in: c, guid: "recent", daysAgo: 3, duration: 100, downloaded: true)
        let old = episode(in: c, guid: "old", daysAgo: 30, duration: 100, downloaded: true)
        let recentNotDownloaded = episode(in: c, guid: "rnd", daysAgo: 2, duration: 100)
        let result = SmartQueue.recentlyAdded.apply(to: [recent, old, recentNotDownloaded])
        XCTAssertEqual(result.map(\.guid), ["recent"], "recently added shows only downloaded episodes")
    }

    func test_shortestFirst_downloadedOnly_sortsByDuration_excludesPlayed() throws {
        let c = try ctx()
        let long = episode(in: c, guid: "long", daysAgo: 1, duration: 3600, downloaded: true)
        let short = episode(in: c, guid: "short", daysAgo: 1, duration: 600, downloaded: true)
        let playedShort = episode(in: c, guid: "ps", daysAgo: 1, duration: 100, played: true, downloaded: true)
        let shorterNotDownloaded = episode(in: c, guid: "snd", daysAgo: 1, duration: 60)
        let result = SmartQueue.shortestFirst.apply(to: [long, short, playedShort, shorterNotDownloaded])
        XCTAssertEqual(result.map(\.guid), ["short", "long"], "shortest shows only downloaded episodes")
    }

    func test_unplayed_excludesArchived() throws {
        let c = try ctx()
        let live = episode(in: c, guid: "live", daysAgo: 1, duration: 100, downloaded: true)
        let archived = episode(in: c, guid: "archived", daysAgo: 0.5, duration: 100, downloaded: true)
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
        XCTAssertFalse(SmartQueue.recentlyAdded.hasMatches(in: [played]),
                       "recently added is downloaded-only — not downloaded, no match")

        let fresh = episode(in: c, guid: "f", daysAgo: 1, duration: 100, downloaded: true)
        XCTAssertTrue(SmartQueue.unplayed.hasMatches(in: [played, fresh]))
        XCTAssertTrue(SmartQueue.downloaded.hasMatches(in: [played, fresh]))
        XCTAssertTrue(SmartQueue.shortestFirst.hasMatches(in: [played, fresh]))
        XCTAssertTrue(SmartQueue.recentlyAdded.hasMatches(in: [played, fresh]))
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
