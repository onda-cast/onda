//  ArticleExtractorTests.swift
import XCTest
@testable import Onda

@MainActor
final class ArticleExtractorTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "html")!
        return try Data(contentsOf: url)
    }

    func test_extractsArticleFromFixture_strippingChrome() async throws {
        let html = try fixture("article_basic")
        let extractor = ArticleExtractor(fetch: { _ in html })
        let article = try await extractor.extract(from: URL(string: "https://example.com/terns")!)
        XCTAssertEqual(article.title, "The Long Migration")
        XCTAssertTrue(article.textContent.contains("Arctic terns"))
        XCTAssertTrue(article.textContent.contains("krill blooms"))
        XCTAssertFalse(article.textContent.contains("SUBSCRIBE NOW"), "nav/aside chrome must be stripped")
    }

    func test_pageWithNoArticle_throwsNoReadableContent() async {
        let html = Data("<html><body><nav><a href='/'>Home</a></nav></body></html>".utf8)
        let extractor = ArticleExtractor(fetch: { _ in html })
        do {
            _ = try await extractor.extract(from: URL(string: "https://example.com/empty")!)
            XCTFail("expected noReadableContent")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .noReadableContent)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_nonHTTPScheme_throwsInvalidURL() async {
        let extractor = ArticleExtractor(fetch: { _ in Data() })
        do {
            _ = try await extractor.extract(from: URL(string: "ftp://example.com/x")!)
            XCTFail("expected invalidURL")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .invalidURL)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_fetchError_throwsFetchFailed() async {
        struct Boom: Error {}
        let extractor = ArticleExtractor(fetch: { _ in throw Boom() })
        do {
            _ = try await extractor.extract(from: URL(string: "https://example.com/x")!)
            XCTFail("expected fetchFailed")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .fetchFailed)
        } catch { XCTFail("unexpected error \(error)") }
    }
}
