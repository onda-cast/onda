//  RSSFeedParserTests.swift
import XCTest
@testable import Onda

@MainActor
final class RSSFeedParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "xml")!
        return try Data(contentsOf: url)
    }

    func test_parseBasic_extractsChannelAndEpisode() throws {
        let feed = RSSFeedParser().parse(try fixture("feed_basic"))
        let f = try XCTUnwrap(feed)
        XCTAssertEqual(f.title, "The Signal")
        XCTAssertEqual(f.author, "Ex Media")
        XCTAssertEqual(f.category, "Technology")
        XCTAssertEqual(f.artworkURL, URL(string: "https://ex.com/art.jpg"))
        XCTAssertEqual(f.episodes.count, 1)
        let ep = f.episodes[0]
        XCTAssertEqual(ep.guid, "sig-142")
        XCTAssertEqual(ep.duration, 2292)
        XCTAssertEqual(ep.audioURL, URL(string: "https://ex.com/142.mp3"))
        XCTAssertEqual(ep.chaptersURL, URL(string: "https://ex.com/142-chapters.json"))
    }

    func test_parseMessy_skipsItemWithoutAudio_andParsesHMSDuration() throws {
        let feed = RSSFeedParser().parse(try fixture("feed_messy"))
        let f = try XCTUnwrap(feed)
        XCTAssertEqual(f.episodes.count, 1, "episode without an enclosure URL is skipped")
        XCTAssertEqual(f.episodes[0].guid, "good-1")
        XCTAssertEqual(f.episodes[0].duration, 3723) // 1:02:03
    }

    func test_parseDuration_handlesFormats() {
        XCTAssertEqual(RSSFeedParser.parseDuration("3600"), 3600)
        XCTAssertEqual(RSSFeedParser.parseDuration("02:03"), 123)
        XCTAssertEqual(RSSFeedParser.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(RSSFeedParser.parseDuration("garbage"), 0)
    }
}
