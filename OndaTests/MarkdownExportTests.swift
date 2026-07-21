//  MarkdownExportTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class MarkdownExportTests: XCTestCase {
    private struct TestEnv {
        let context: ModelContext
        let episode1: Episode
        let episode2: Episode
    }

    private func makeEnv() throws -> TestEnv {
        let c = try ModelContainer(for: Schema(ondaSchema),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal",
                          author: "A", artworkURL: nil, category: "Tech", itunesId: 1)
        let ep1 = Episode(guid: "g1", title: "Ep 142", publishDate: .now, duration: 3000,
                          audioURL: URL(string: "https://ex.com/1.mp3")!, notes: "")
        let ep2 = Episode(guid: "g2", title: "Ep 143", publishDate: .now, duration: 3000,
                          audioURL: URL(string: "https://ex.com/2.mp3")!, notes: "")
        ep1.podcast = pod; ep2.podcast = pod
        ctx.insert(pod); ctx.insert(ep1); ctx.insert(ep2)
        return TestEnv(context: ctx, episode1: ep1, episode2: ep2)
    }

    private func clip(_ ep: Episode, start: TimeInterval, text: String, note: String?) -> Clip {
        let c = Clip(startTime: start, endTime: start + 30, text: text, note: note,
                     createdAt: .now, needsReview: false)
        c.episode = ep; ep.clips.append(c)
        return c
    }

    func test_clipMarkdown_quoteAttributionAndNote() throws {
        let ep = try makeEnv().episode1
        let c = clip(ep, start: 754, text: "the homepage is dead", note: "use in essay")
        let md = MarkdownExport.clipMarkdown(c)
        XCTAssertTrue(md.contains("> the homepage is dead"))
        XCTAssertTrue(md.contains("Ep 142"))
        XCTAssertTrue(md.contains("The Signal"))
        XCTAssertTrue(md.contains("12:34"))
        XCTAssertTrue(md.contains("**Note:** use in essay"),
                      "markdown export is personal — notes ARE included")
    }

    func test_clipMarkdown_noTranscript_noQuoteBlock() throws {
        let ep = try makeEnv().episode1
        let c = clip(ep, start: 60, text: "", note: nil)
        let md = MarkdownExport.clipMarkdown(c)
        XCTAssertFalse(md.contains(">"))
        XCTAssertTrue(md.contains("1:00"))
    }

    func test_document_groupsByShowThenEpisode() throws {
        let env = try makeEnv()
        let ep1 = env.episode1, ep2 = env.episode2
        let c1 = clip(ep1, start: 10, text: "one", note: nil)
        let c2 = clip(ep2, start: 20, text: "two", note: nil)
        let c3 = clip(ep1, start: 30, text: "three", note: nil)
        let md = MarkdownExport.document(clips: [c2, c1, c3])
        XCTAssertTrue(md.contains("# Onda Clips"))
        XCTAssertTrue(md.contains("## The Signal"))
        XCTAssertEqual(md.components(separatedBy: "## The Signal").count, 2, "one show header")
        XCTAssertTrue(md.contains("### Ep 142"))
        XCTAssertTrue(md.contains("### Ep 143"))
        // Within Ep 142, clips ordered by start time.
        let ep142Range = try XCTUnwrap(md.range(of: "### Ep 142")?.lowerBound) ..< md.range(of: "### Ep 143")!.lowerBound
        let section = String(md[ep142Range])
        XCTAssertLessThan(try XCTUnwrap(section.range(of: "one")?.lowerBound),
                          try XCTUnwrap(section.range(of: "three")?.lowerBound))
    }
}
