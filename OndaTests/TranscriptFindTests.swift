//  TranscriptFindTests.swift
import XCTest
@testable import Onda

final class TranscriptFindTests: XCTestCase {
    private let texts = [
        "Welcome back to the show today",          // 0
        "Penicillin was discovered by accident",   // 1
        "The mold genus is Penicillium",           // 2
        "Nothing relevant here",                   // 3
    ]

    // matchingIndices
    func test_matchingIndices_caseInsensitive() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "penicill", in: texts), [1, 2])
    }
    func test_matchingIndices_emptyQuery_matchesNothing() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "", in: texts), [])
    }
    func test_matchingIndices_whitespaceQuery_matchesNothing() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "   ", in: texts), [])
    }
    func test_matchingIndices_noHits() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: "zebra", in: texts), [])
    }
    func test_matchingIndices_trimsQueryBeforeMatching() {
        XCTAssertEqual(TranscriptFind.matchingIndices(query: " mold ", in: texts), [2])
    }

    // segments
    func test_segments_splitsAroundMatch() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "The mold genus", query: "mold"),
            [.init(text: "The ", isMatch: false),
             .init(text: "mold", isMatch: true),
             .init(text: " genus", isMatch: false)])
    }
    func test_segments_matchIsCaseInsensitive_preservesOriginalCasing() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "Penicillin and penicillium", query: "PENICILL"),
            [.init(text: "Penicill", isMatch: true),
             .init(text: "in and ", isMatch: false),
             .init(text: "penicill", isMatch: true),
             .init(text: "ium", isMatch: false)])
    }
    func test_segments_noMatch_returnsWholeTextUnmatched() {
        XCTAssertEqual(TranscriptFind.segments(of: "Hello there", query: "zebra"),
                       [.init(text: "Hello there", isMatch: false)])
    }
    func test_segments_emptyQuery_returnsWholeTextUnmatched() {
        XCTAssertEqual(TranscriptFind.segments(of: "Hello", query: ""),
                       [.init(text: "Hello", isMatch: false)])
    }
    func test_segments_matchAtStartAndEnd() {
        XCTAssertEqual(
            TranscriptFind.segments(of: "ha in the middle ha", query: "ha"),
            [.init(text: "ha", isMatch: true),
             .init(text: " in the middle ", isMatch: false),
             .init(text: "ha", isMatch: true)])
    }
    func test_segments_reassembleToOriginalText() {
        let original = "Alexander Fleming noticed a contaminated petri dish"
        let joined = TranscriptFind.segments(of: original, query: "a").map(\.text).joined()
        XCTAssertEqual(joined, original)
    }
}
