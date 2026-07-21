//  BookLinkParserTests.swift
import XCTest
@testable import Onda

final class BookLinkParserTests: XCTestCase {
    private func url(_ s: String) -> URL {
        URL(string: s)!
    }

    func test_amazonDP_yieldsASINCandidate() {
        let c = BookLinkParser.candidates(from: [url("https://www.amazon.com/dp/0735211299?tag=aff-20")])
        XCTAssertEqual(c, [BookCandidate(title: nil, author: nil, isbnOrASIN: "0735211299",
                                         timestamp: nil, sourceTier: "link")])
    }

    func test_amazonGPProduct_yieldsASIN() {
        let c = BookLinkParser.candidates(from: [url("https://amazon.com/gp/product/B07D23CFGR")])
        XCTAssertEqual(c.first?.isbnOrASIN, "B07D23CFGR")
    }

    func test_bookshopSlug_yieldsTitleWords() {
        let c = BookLinkParser.candidates(from: [url("https://bookshop.org/p/books/deep-work-cal-newport/8339063")])
        XCTAssertEqual(c.first?.title, "deep work cal newport")
        XCTAssertEqual(c.first?.sourceTier, "link")
    }

    func test_goodreadsSlug_yieldsTitleWords() {
        let c = BookLinkParser.candidates(from: [url("https://www.goodreads.com/book/show/40121378-atomic-habits")])
        XCTAssertEqual(c.first?.title, "atomic habits")
    }

    func test_irrelevantLinks_yieldNothing() {
        let c = BookLinkParser.candidates(from: [url("https://patreon.com/show"),
                                                 url("https://amazon.com/some-page")])
        XCTAssertTrue(c.isEmpty)
    }
}
