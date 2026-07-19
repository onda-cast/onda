//  StorageBreakdownTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class StorageBreakdownTests: XCTestCase {
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func makePodcast(_ ctx: ModelContext, title: String, feed: String) -> Podcast {
        let p = Podcast(feedURL: URL(string: feed)!, title: title, author: "A",
                        artworkURL: nil, category: "Tech", itunesId: 1)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func addEpisode(_ ctx: ModelContext, to pod: Podcast, guid: String,
                            audioBytes: Int64? = nil, cueTexts: [String] = []) -> Episode {
        let ep = Episode(guid: guid, title: guid, publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/\(guid).mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep)
        if let audioBytes {
            let f = DownloadedFile(localFileName: "\(guid).mp3", fileSizeBytes: audioBytes, downloadedAt: .now)
            f.episode = ep; ep.downloadedFile = f; ctx.insert(f)
        }
        if !cueTexts.isEmpty {
            let tr = Transcript(source: "published", language: "en")
            tr.episode = ep; ep.transcript = tr; ctx.insert(tr)
            var cues: [TranscriptCue] = []
            for (i, text) in cueTexts.enumerated() {
                let cue = TranscriptCue(startTime: Double(i), endTime: Double(i + 1), text: text, speaker: nil)
                cue.transcript = tr; ctx.insert(cue); cues.append(cue)
            }
            tr.cues = cues
        }
        ctx.insert(ep)
        return ep
    }

    func test_breakdown_sumsAudioAndTranscriptPerPodcast() throws {
        let ctx = try ctx()
        let a = makePodcast(ctx, title: "A", feed: "https://a.com/f.xml")
        addEpisode(ctx, to: a, guid: "a1", audioBytes: 1000, cueTexts: ["hello", "world"]) // 5+5=10
        addEpisode(ctx, to: a, guid: "a2", audioBytes: 500)
        let b = makePodcast(ctx, title: "B", feed: "https://b.com/f.xml")
        addEpisode(ctx, to: b, guid: "b1", cueTexts: ["abc"]) // 3 bytes, no audio

        let bd = StorageCalculator.breakdown(podcasts: [a, b])
        XCTAssertEqual(bd.audioBytes, 1500)
        XCTAssertEqual(bd.transcriptBytes, 13)
        XCTAssertEqual(bd.totalBytes, 1513)
        XCTAssertEqual(bd.podcasts.count, 2)
        XCTAssertEqual(bd.podcasts.first?.title, "A", "rows sorted by total size descending")
        XCTAssertEqual(bd.podcasts.first?.audioBytes, 1500)
        XCTAssertEqual(bd.podcasts.first?.transcriptBytes, 10)
    }

    func test_breakdown_skipsPodcastsWithNoStorage() throws {
        let ctx = try ctx()
        let empty = makePodcast(ctx, title: "Empty", feed: "https://e.com/f.xml")
        addEpisode(ctx, to: empty, guid: "e1") // no audio, no transcript
        let bd = StorageCalculator.breakdown(podcasts: [empty])
        XCTAssertTrue(bd.podcasts.isEmpty)
        XCTAssertEqual(bd.totalBytes, 0)
    }
    func test_cache_roundTripsAndSurvivesForNextColdOpen() {
        let defaults = UserDefaults(suiteName: "storage-\(UUID().uuidString)")!
        XCTAssertNil(StorageCalculator.cachedBreakdown(defaults: defaults), "empty cache -> nil")

        let bd = StorageBreakdown(audioBytes: 1500, transcriptBytes: 10, podcasts: [
            StoragePodcastRow(id: "https://a.com/f.xml", title: "A", audioBytes: 1500, transcriptBytes: 10)
        ])
        StorageCalculator.saveCache(bd, defaults: defaults)
        XCTAssertEqual(StorageCalculator.cachedBreakdown(defaults: defaults), bd,
                       "cached snapshot round-trips exactly for the instant first paint")
    }

    func test_cache_corruptDataDecodesToNil() {
        let defaults = UserDefaults(suiteName: "storage-\(UUID().uuidString)")!
        defaults.set(Data("not json".utf8), forKey: StorageCalculator.cacheKey)
        XCTAssertNil(StorageCalculator.cachedBreakdown(defaults: defaults),
                     "corrupt/old-format cache falls back to a fresh measure, never crashes")
    }

}
