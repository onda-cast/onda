//  SmartQueryParserTests.swift
import XCTest
@testable import Onda

@MainActor
final class SmartQueryParserTests: XCTestCase {
    private let shows = ["Odd Lots", "The Signal", "Slow Burn Kitchen"]

    func test_fullNaturalQuery_extractsShowSpeakerAndTerms() {
        let q = SmartQueryParser.parse("book mentioned by michael in Odd Lots", knownShows: shows)
        XCTAssertEqual(q.show, "Odd Lots")
        XCTAssertEqual(q.speaker, "Michael")
        XCTAssertEqual(q.terms, ["book"])
    }

    func test_showMatch_isCaseInsensitive_andPartial() {
        let q = SmartQueryParser.parse("inflation in odd lots", knownShows: shows)
        XCTAssertEqual(q.show, "Odd Lots")
        XCTAssertEqual(q.terms, ["inflation"])
    }

    func test_noFilters_allWordsBecomeTerms_minusStopwords() {
        let q = SmartQueryParser.parse("what was the moneyball quote", knownShows: shows)
        XCTAssertNil(q.show); XCTAssertNil(q.speaker)
        XCTAssertEqual(q.terms, ["moneyball", "quote"])
    }

    func test_speakerWithoutShow() {
        let q = SmartQueryParser.parse("gold standard by Tracy", knownShows: shows)
        XCTAssertEqual(q.speaker, "Tracy")
        XCTAssertNil(q.show)
        XCTAssertEqual(q.terms, ["gold", "standard"])
    }

    func test_ftsExpression_joinsTermsForMatch() {
        let q = SmartQuery(terms: ["gold", "standard"], speaker: nil, show: nil)
        XCTAssertEqual(q.ftsQueryText, "gold standard")
    }

    // MARK: NLP tier (NLTagger)

    func test_multiWordSpeakerName_afterBy() {
        let q = SmartQueryParser.parse("gold standard by Tracy Alloway", knownShows: shows)
        XCTAssertEqual(q.speaker, "Tracy Alloway")
        XCTAssertEqual(q.terms, ["gold", "standard"])
    }

    func test_personName_recognizedWithoutByPhrase() {
        let q = SmartQueryParser.parse("what did Tracy Alloway say about inflation",
                                       knownShows: shows)
        XCTAssertEqual(q.speaker, "Tracy Alloway")
        XCTAssertTrue(q.terms.contains("inflation"))
        XCTAssertFalse(q.terms.contains("tracy"), "speaker name must not leak into terms")
    }

    func test_lemmatization_normalizesPlurals() {
        let q = SmartQueryParser.parse("books mentioned in Odd Lots", knownShows: shows)
        XCTAssertEqual(q.show, "Odd Lots")
        XCTAssertEqual(q.terms, ["book"], "plural should lemmatize to singular")
    }

    func test_posFiltering_dropsFunctionWords_keepsContent() {
        let q = SmartQueryParser.parse("the very volatile trading strategies", knownShows: shows)
        XCTAssertFalse(q.terms.contains("the"))
        XCTAssertFalse(q.terms.contains("very"))
        XCTAssertTrue(q.terms.contains("volatile"))
        XCTAssertTrue(q.terms.contains("strategy") || q.terms.contains("trading"),
                      "content words survive with lemmas")
    }
}
