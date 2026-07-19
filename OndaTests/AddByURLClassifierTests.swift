//  AddByURLClassifierTests.swift
import XCTest
@testable import Onda

@MainActor
final class AddByURLClassifierTests: XCTestCase {
    func test_xmlContentTypes_areBrokenFeeds() {
        for ct in ["application/rss+xml", "application/atom+xml", "text/xml",
                   "application/xml; charset=utf-8"] {
            XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: ct, bodyPrefix: ""),
                           .brokenFeed, ct)
        }
    }

    func test_htmlContentTypes_areWebPages_evenXhtml() {
        for ct in ["text/html", "text/html; charset=utf-8", "application/xhtml+xml"] {
            XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: ct, bodyPrefix: "<html>"),
                           .webPage, ct)
        }
    }

    func test_missingContentType_fallsBackToBodySniff() {
        XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: nil,
                                                     bodyPrefix: "  <?xml version=\"1.0\"?><rss>"),
                       .brokenFeed)
        XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: nil, bodyPrefix: "<rss version=\"2.0\">"),
                       .brokenFeed)
        XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: nil, bodyPrefix: "<feed xmlns="),
                       .brokenFeed)
        XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: nil, bodyPrefix: "<!DOCTYPE html><html>"),
                       .webPage)
    }

    func test_genericContentType_withHtmlBody_isWebPage() {
        XCTAssertEqual(AddByURLSheet.classifyNonFeed(contentType: "application/octet-stream",
                                                     bodyPrefix: "<!DOCTYPE html>"),
                       .webPage)
    }
}
