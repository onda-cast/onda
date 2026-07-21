//  RecommendationScoringTests.swift
import XCTest
@testable import Onda

final class RecommendationScoringTests: XCTestCase {
    // MARK: TermVector / cosine / TF-IDF

    func test_tokenizer_dropsStopwordsAndShortWords() {
        let terms = RecTokenizer.terms(in: "The best espresso podcast about coffee and portafilters")
        XCTAssertFalse(terms.contains("the"))
        XCTAssertFalse(terms.contains("and"))
        XCTAssertFalse(terms.contains("podcast"), "boilerplate stopword")
        XCTAssertTrue(terms.contains("espresso"))
        XCTAssertTrue(terms.contains("portafilters"))
    }

    func test_cosine_identicalIsOne_disjointIsZero() {
        let a = TermVector(text: "espresso coffee beans")
        XCTAssertEqual(a.cosine(a), 1.0, accuracy: 1e-9)
        let b = TermVector(text: "quantum galaxy nebula")
        XCTAssertEqual(a.cosine(b), 0.0, accuracy: 1e-9)
    }

    func test_cosine_partialOverlapBetweenZeroAndOne() {
        let a = TermVector(text: "espresso coffee beans grinder")
        let b = TermVector(text: "espresso latte")
        let c = a.cosine(b)
        XCTAssertGreaterThan(c, 0)
        XCTAssertLessThan(c, 1)
    }

    func test_idf_downweightsCommonTerms() throws {
        let docs = [TermVector(text: "coffee espresso"), TermVector(text: "coffee tea"),
                    TermVector(text: "coffee milk")]
        let idf = TFIDF.idf(documents: docs)
        // "coffee" is in every doc, "espresso" in one → espresso must weigh more.
        XCTAssertLessThan(try XCTUnwrap(idf["coffee"]), try XCTUnwrap(idf["espresso"]))
    }

    func test_topTermsAndOverlap() {
        var v = TermVector()
        v.add(text: "espresso espresso espresso coffee", weight: 1)
        XCTAssertEqual(v.topTerms(1), ["espresso"])
        let other = TermVector(text: "coffee latte")
        XCTAssertEqual(v.overlap(with: other, limit: 5), ["coffee"])
    }

    // MARK: Hybrid scorer + embedding fallback

    /// Fake embedding: each word maps to a one-hot axis, so cosine == keyword overlap-ish but
    /// exercises the blend path deterministically.
    private struct OneHotEmbedding: WordEmbedding {
        let axis: [String: Int]
        let dims: Int
        func vector(for word: String) -> [Double]? {
            guard let i = axis[word] else { return nil }
            var v = [Double](repeating: 0, count: dims)
            v[i] = 1
            return v
        }
    }

    func test_hybrid_fallsBackToKeywordOnly_whenNoEmbedding() {
        let profile = TermVector(text: "espresso coffee")
        let cand = TermVector(text: "espresso latte")
        let idf = TFIDF.idf(documents: [profile, cand])
        let keywordOnly = HybridScorer.score(profile: profile, candidate: cand, idf: idf, embedding: nil)
        XCTAssertGreaterThan(keywordOnly, 0, "keyword-only path still scores overlap")
    }

    func test_hybrid_blendsEmbeddingWhenPresent() {
        let profile = TermVector(text: "espresso coffee")
        let cand = TermVector(text: "espresso latte")
        let idf = TFIDF.idf(documents: [profile, cand])
        let embedding = OneHotEmbedding(axis: ["espresso": 0, "coffee": 1, "latte": 2], dims: 3)
        let blended = HybridScorer.score(profile: profile, candidate: cand, idf: idf, embedding: embedding)
        let keywordOnly = HybridScorer.score(profile: profile, candidate: cand, idf: idf, embedding: nil)
        XCTAssertNotEqual(blended, keywordOnly, "embedding half shifts the blended score")
        XCTAssertGreaterThan(blended, 0)
    }

    func test_embedding_nilWhenNoTermsEmbed() {
        let embedding = OneHotEmbedding(axis: [:], dims: 3)
        XCTAssertNil(EmbeddingSimilarity.score(["espresso"], ["latte"], using: embedding))
    }
}
