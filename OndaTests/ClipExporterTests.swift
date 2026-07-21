//  ClipExporterTests.swift
import XCTest
import AVFoundation
import SwiftData
@testable import Onda

@MainActor
final class ClipExporterTests: XCTestCase {
    private func makeClip(start: TimeInterval, end: TimeInterval,
                          text: String = "alpha beta") throws -> Clip {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal",
                          author: "A", artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g", title: "Ep 142", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        let clip = Clip(startTime: start, endTime: end, text: text,
                        note: "private!", createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip)
        ctx.insert(pod); ctx.insert(ep); ctx.insert(clip)
        return clip
    }

    func test_shareText_includesExcerptAndAttribution_neverNote() throws {
        let clip = try makeClip(start: 754, end: 760)
        let text = ClipExporter.shareText(for: clip)
        XCTAssertTrue(text.contains("\u{201C}alpha beta\u{201D}"))
        XCTAssertTrue(text.contains("Ep 142"))
        XCTAssertTrue(text.contains("The Signal"))
        XCTAssertTrue(text.contains("12:34"))
        XCTAssertFalse(text.contains("private!"), "user note must never leave the device")
    }

    func test_shareText_truncatesLongExcerpts() throws {
        let long = String(repeating: "word ", count: 200)
        let clip = try makeClip(start: 0, end: 10, text: long)
        let text = ClipExporter.shareText(for: clip)
        XCTAssertLessThan(text.count, 420)
        XCTAssertTrue(text.contains("\u{2026}"))
    }

    func test_export_producesM4aOfClipRange() async throws {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spoken", withExtension: "aiff"))
        let clip = try makeClip(start: 1, end: 3)
        let exporter = ClipExporter(sourceURL: { _ in src })
        let out = try await exporter.export(clip: clip)
        XCTAssertEqual(out.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.5)
    }
}
