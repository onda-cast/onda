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
}
