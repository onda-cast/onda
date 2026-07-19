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
}
