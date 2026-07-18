//  SentenceSplitterTests.swift
import XCTest
@testable import Onda

final class SentenceSplitterTests: XCTestCase {
    func test_splitsProseIntoSentences() {
        let text = "The tern flew south. It crossed two oceans! Where would it land next? Nobody knew."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["The tern flew south.", "It crossed two oceans!",
                        "Where would it land next?", "Nobody knew."])
    }

    func test_handlesAbbreviationsAndNewlines() {
        let text = "Dr. Smith arrived at 5 p.m. on Tuesday.\n\nShe left early."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["Dr. Smith arrived at 5 p.m. on Tuesday.", "She left early."])
    }

    func test_emptyAndWhitespaceOnly_returnEmpty() {
        XCTAssertEqual(SentenceSplitter.split(""), [])
        XCTAssertEqual(SentenceSplitter.split("  \n\t "), [])
    }
}
