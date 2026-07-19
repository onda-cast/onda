//  BookVerifierTests.swift
import XCTest
@testable import Onda

final class BookVerifierTests: XCTestCase {
    private func olResponse(_ docs: [[String: Any]]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: ["docs": docs])
    }

    private func stub(_ data: Data) -> BookVerifier {
        BookVerifier(transport: { _ in data })
    }

    func test_exactMatch_verifies() async {
        let v = stub(olResponse([["key": "/works/OL123W", "title": "Atomic Habits",
                                  "author_name": ["James Clear"], "cover_i": 123]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertEqual(out?.workKey, "/works/OL123W")
        XCTAssertEqual(out?.author, "James Clear")
        XCTAssertEqual(out?.coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/123-M.jpg")
    }

    func test_dissimilarTitle_rejected() async {
        let v = stub(olResponse([["key": "/works/OL9W", "title": "A Completely Different Book",
                                  "author_name": ["James Clear"]]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out, "similarity below threshold must be dropped, never shown")
    }

    func test_authorMismatch_rejected() async {
        let v = stub(olResponse([["key": "/works/OL5W", "title": "Atomic Habits",
                                  "author_name": ["Somebody Else"]]]))
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: "James Clear",
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out)
    }

    func test_transportFailure_returnsNil() async {
        let v = BookVerifier(transport: { _ in throw URLError(.notConnectedToInternet) })
        let out = await v.verify(BookCandidate(title: "Atomic Habits", author: nil,
                                               isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        XCTAssertNil(out, "network failure = unverified = dropped, no crash")
    }

    func test_titleSimilarity_subtitleDropStillMatches() {
        XCTAssertGreaterThanOrEqual(
            BookVerifier.titleSimilarity("deep work",
                                         "Deep Work: Rules for Focused Success"), 0.85)
        XCTAssertLessThan(BookVerifier.titleSimilarity("sapiens", "homo deus"), 0.85)
    }
}
