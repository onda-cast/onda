//  RSSFeedParserTests.swift
import XCTest
@testable import Onda

@MainActor
final class RSSFeedParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "xml")!
        return try Data(contentsOf: url)
    }

    // Regression: fetchFeed used to run the synchronous XMLParser pass directly on the
    // caller's actor (@MainActor SubscriptionService), freezing the UI on large feeds. It now
    // hops to Task.detached — this confirms that refactor still parses correctly end-to-end.
    func test_client_fetchFeed_parsesViaDetachedTask() async throws {
        let data = try fixture("feed_basic")
        let client = RSSFeedClient(transport: { _ in data })
        let feed = try await client.fetchFeed(XCTUnwrap(URL(string: "https://ex.com/feed.xml")))
        XCTAssertEqual(feed.title, "The Signal")
        XCTAssertEqual(feed.episodes.count, 1)
    }

    func test_parseBasic_extractsChannelAndEpisode() throws {
        let feed = try RSSFeedParser().parse(fixture("feed_basic"))
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
        let feed = try RSSFeedParser().parse(fixture("feed_messy"))
        let f = try XCTUnwrap(feed)
        XCTAssertEqual(f.episodes.count, 1, "episode without an enclosure URL is skipped")
        XCTAssertEqual(f.episodes[0].guid, "good-1")
        XCTAssertEqual(f.episodes[0].duration, 3723) // 1:02:03
    }

    func test_notes_decodeHTMLEntities() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>S</title>
        <item><title>E</title><guid>g</guid>
        <enclosure url="https://ex.com/e.mp3" type="audio/mpeg"/>
        <description>Stats &amp;amp; analytics &amp;mdash; it&amp;#8217;s &amp;quot;moneyball&amp;quot;&amp;hellip;</description>
        </item></channel></rss>
        """
        let feed = RSSFeedParser().parse(Data(xml.utf8))
        XCTAssertEqual(try XCTUnwrap(feed).episodes.first?.notes,
                       "Stats & analytics \u{2014} it\u{2019}s \"moneyball\"\u{2026}")
    }

    func test_parseDuration_handlesFormats() {
        XCTAssertEqual(RSSFeedParser.parseDuration("3600"), 3600)
        XCTAssertEqual(RSSFeedParser.parseDuration("02:03"), 123)
        XCTAssertEqual(RSSFeedParser.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(RSSFeedParser.parseDuration("garbage"), 0)
    }

    func test_parse_capturesNoteLinksBeforeStrippingHTML() throws {
        let xml = """
        <rss><channel><title>Show</title>
        <item><title>Ep</title><guid>g1</guid>
        <description><![CDATA[Great chat. <a href="https://www.amazon.com/dp/0735211299">Atomic Habits</a> \
        and <a href='https://bookshop.org/p/books/deep-work-cal-newport/8339063'>Deep Work</a>]]></description>
        <enclosure url="https://ex.com/e1.mp3" type="audio/mpeg" length="1"/>
        </item></channel></rss>
        """
        let feed = try XCTUnwrap(RSSFeedParser().parse(Data(xml.utf8)))
        let ep = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(ep.noteLinks.map(\.absoluteString),
                       ["https://www.amazon.com/dp/0735211299",
                        "https://bookshop.org/p/books/deep-work-cal-newport/8339063"])
        XCTAssertFalse(ep.notes.contains("<a "), "notes stay stripped plain text")
    }
}
