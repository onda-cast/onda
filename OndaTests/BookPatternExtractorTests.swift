//  BookPatternExtractorTests.swift
import XCTest
@testable import Onda

final class BookPatternExtractorTests: XCTestCase {
    // People named Cal Newport / James Clear exist; "Next Week" is not a person.
    private let extractor = BookPatternExtractor(isPersonName: { name in
        ["Cal Newport", "James Clear"].contains(name)
    })

    func test_quotedTitleByPerson_inNotes() {
        let c = extractor.candidates(fromNotes: #"We loved "Deep Work" by Cal Newport this week."#)
        XCTAssertEqual(c, [BookCandidate(title: "Deep Work", author: "Cal Newport",
                                         isbnOrASIN: nil, timestamp: nil, sourceTier: "notes")])
    }

    func test_byNonPerson_rejected() {
        let c = extractor.candidates(fromNotes: #"More episodes "Coming Soon" by Next Week."#)
        XCTAssertTrue(c.isEmpty, "the by-clause must name a verified person")
    }

    func test_readingListBlock_inNotes() {
        let notes = """
        Great episode!
        Books mentioned:
        Atomic Habits — James Clear
        Deep Work — Cal Newport
        """
        let c = extractor.candidates(fromNotes: notes)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].title, "Atomic Habits")
        XCTAssertEqual(c[0].author, "James Clear")
    }

    func test_cueMatches_carryTimestamps() {
        let cues = [(text: #"I just finished "Atomic Habits" by James Clear"#, start: 812.0)]
        let c = extractor.candidates(fromCues: cues)
        XCTAssertEqual(c.first?.timestamp, 812.0)
        XCTAssertEqual(c.first?.sourceTier, "transcript")
    }

    // "author of [the] [new] book <Title>" — person introduced first, unquoted title running to
    // the next clause boundary. Title-only candidate (OpenLibrary resolves the author).
    func test_authorOfBook_unquotedTitle_inNotes() {
        let notes = "Noah Rothman is a senior writer at National Review and author of the "
            + "new book Blood & Progress, which argues for optimism."
        let c = extractor.candidates(fromNotes: notes)
        XCTAssertTrue(c.contains { $0.title == "Blood & Progress" && $0.author == nil },
                      "captures the unquoted title up to the comma")
    }

    func test_authorOfBook_stopsAtSentenceEnd() {
        let c = extractor.candidates(fromNotes: "She is the author of the book Educated. Highly recommend.")
        XCTAssertTrue(c.contains { $0.title == "Educated" }, "title stops at the period")
        XCTAssertFalse(c.contains { $0.title?.contains("recommend") ?? false })
    }

    func test_authorOfBook_carriesCueTimestamp() {
        let cues = [(text: "He is the author of the book The Overstory, a Pulitzer winner", start: 240.0)]
        let c = extractor.candidates(fromCues: cues)
        XCTAssertEqual(c.first { $0.title == "The Overstory" }?.timestamp, 240.0)
    }
}
