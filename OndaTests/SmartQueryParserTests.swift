//  SmartQueryParserTests.swift
import NaturalLanguage
import XCTest
@testable import Onda

@MainActor
final class SmartQueryParserTests: XCTestCase {
    private let shows = ["Odd Lots", "The Signal", "Slow Burn Kitchen"]

    /// The NaturalLanguage English models are fetched on demand (MobileAsset) and can be
    /// unavailable in a simulator — NLTagger then silently degrades to nil lemmas, "OtherWord"
    /// lexical classes, and no name recognition (see docs/BUGS.md #2). Probe both schemes the
    /// parser relies on and skip NL-dependent assertions when the models aren't loaded.
    private func skipUnlessNLAssetsAvailable() throws {
        let lemmaProbe = "books"
        let lemmaTagger = NLTagger(tagSchemes: [.lemma])
        lemmaTagger.string = lemmaProbe
        lemmaTagger.setLanguage(.english, range: lemmaProbe.startIndex..<lemmaProbe.endIndex)
        let lemma = lemmaTagger.tag(at: lemmaProbe.startIndex, unit: .word, scheme: .lemma).0

        let nameProbe = "Tim Cook spoke yesterday"
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = nameProbe
        nameTagger.setLanguage(.english, range: nameProbe.startIndex..<nameProbe.endIndex)
        let nameTag = nameTagger.tag(at: nameProbe.startIndex, unit: .word, scheme: .nameType).0

        try XCTSkipIf(lemma == nil || nameTag != .personalName,
                      "NaturalLanguage English model assets unavailable in this environment")
    }

    func test_fullNaturalQuery_extractsShowSpeakerAndTerms() throws {
        try skipUnlessNLAssetsAvailable()
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

    func test_noFilters_allWordsBecomeTerms_minusStopwords() throws {
        try skipUnlessNLAssetsAvailable()
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

    func test_personName_recognizedWithoutByPhrase() throws {
        try skipUnlessNLAssetsAvailable()
        let q = SmartQueryParser.parse("what did Tracy Alloway say about inflation",
                                       knownShows: shows)
        XCTAssertEqual(q.speaker, "Tracy Alloway")
        XCTAssertTrue(q.terms.contains("inflation"))
        XCTAssertFalse(q.terms.contains("tracy"), "speaker name must not leak into terms")
    }

    func test_lemmatization_normalizesPlurals() throws {
        try skipUnlessNLAssetsAvailable()
        let q = SmartQueryParser.parse("books mentioned in Odd Lots", knownShows: shows)
        XCTAssertEqual(q.show, "Odd Lots")
        XCTAssertEqual(q.terms, ["book"], "plural should lemmatize to singular")
    }

    func test_posFiltering_dropsFunctionWords_keepsContent() throws {
        try skipUnlessNLAssetsAvailable()
        let q = SmartQueryParser.parse("the very volatile trading strategies", knownShows: shows)
        XCTAssertFalse(q.terms.contains("the"))
        XCTAssertFalse(q.terms.contains("very"))
        XCTAssertTrue(q.terms.contains("volatile"))
        XCTAssertTrue(q.terms.contains("strategy") || q.terms.contains("trading"),
                      "content words survive with lemmas")
    }
}
