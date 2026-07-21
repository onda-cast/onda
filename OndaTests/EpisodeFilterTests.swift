//  EpisodeFilterTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class EpisodeFilterTests: XCTestCase {
    private func makeEpisodes() throws -> [Episode] {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        var eps: [Episode] = []
        for i in 0 ..< 25 {
            let ep = Episode(guid: "g\(i)", title: "Ep \(i)",
                             publishDate: Date(timeIntervalSince1970: Double(i) * 86400),
                             duration: 100, audioURL: URL(string: "https://ex.com/\(i).mp3")!, notes: "")
            if i % 5 == 0 {   // every 5th is downloaded
                let f = DownloadedFile(localFileName: "f\(i).mp3", fileSizeBytes: 1, downloadedAt: .now)
                f.episode = ep; ep.downloadedFile = f
            }
            ctx.insert(ep); eps.append(ep)
        }
        return eps
    }

    func test_downloaded_keepsOnlyDownloaded_newestFirst() throws {
        let eps = try makeEpisodes()
        let out = EpisodeFilter.downloaded.apply(to: eps)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.first?.guid, "g20", "newest downloaded first")
        XCTAssertTrue(out.allSatisfy { $0.downloadedFile != nil })
    }

    func test_all_returnsEverything_newestFirst() throws {
        let eps = try makeEpisodes()
        let out = EpisodeFilter.all.apply(to: eps)
        XCTAssertEqual(out.count, 25)
        XCTAssertEqual(out.first?.guid, "g24")
    }

    func test_archivedEpisodes_excludedFromAllFilters() throws {
        let eps = try makeEpisodes()
        eps[24].isArchived = true          // newest, would otherwise lead every list
        eps[20].isArchived = true          // a downloaded one
        XCTAssertEqual(EpisodeFilter.all.apply(to: eps).count, 23)
        XCTAssertEqual(EpisodeFilter.all.apply(to: eps).first?.guid, "g23")
        XCTAssertFalse(EpisodeFilter.downloaded.apply(to: eps).contains { $0.guid == "g20" })
        XCTAssertFalse(EpisodeFilter.newest10.apply(to: eps).contains { $0.isArchived })
    }

    func test_newest10_capsAtTen() throws {
        let eps = try makeEpisodes()
        let out = EpisodeFilter.newest10.apply(to: eps)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out.first?.guid, "g24")
        XCTAssertEqual(out.last?.guid, "g15")
    }
}
