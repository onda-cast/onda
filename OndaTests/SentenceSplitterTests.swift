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

    func test_singleNewlineWithinSentence_joinsIntoOneSentence() {
        let text = "Arctic terns make the longest\nmigration of any animal."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["Arctic terns make the longest migration of any animal."])
    }

    func test_blankLineSeparatedFragments_stayAsSeparateEntries() {
        let text = "The Long Migration\n\nBy Jordan Reyes\n\nFirst real sentence."
        XCTAssertEqual(SentenceSplitter.split(text),
                       ["The Long Migration", "By Jordan Reyes", "First real sentence."])
    }
}
