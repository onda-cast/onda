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
        let article = try await extractor.extract(from: XCTUnwrap(URL(string: "https://example.com/terns")))
        XCTAssertEqual(article.title, "The Long Migration")
        XCTAssertTrue(article.textContent.contains("Arctic terns"))
        XCTAssertTrue(article.textContent.contains("krill blooms"))
        XCTAssertFalse(article.textContent.contains("SUBSCRIBE NOW"), "nav/aside chrome must be stripped")
    }

    func test_pageWithNoArticle_throwsNoReadableContent() async throws {
        let html = Data("<html><body><nav><a href='/'>Home</a></nav></body></html>".utf8)
        let extractor = ArticleExtractor(fetch: { _ in html })
        do {
            _ = try await extractor.extract(from: XCTUnwrap(URL(string: "https://example.com/empty")))
            XCTFail("expected noReadableContent")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .noReadableContent)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_nonHTTPScheme_throwsInvalidURL() async throws {
        let extractor = ArticleExtractor(fetch: { _ in Data() })
        do {
            _ = try await extractor.extract(from: XCTUnwrap(URL(string: "ftp://example.com/x")))
            XCTFail("expected invalidURL")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .invalidURL)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_fetchError_throwsFetchFailed() async throws {
        struct Boom: Error {}
        let extractor = ArticleExtractor(fetch: { _ in throw Boom() })
        do {
            _ = try await extractor.extract(from: XCTUnwrap(URL(string: "https://example.com/x")))
            XCTFail("expected fetchFailed")
        } catch let e as ArticleExtractionError {
            XCTAssertEqual(e, .fetchFailed)
        } catch { XCTFail("unexpected error \(error)") }
    }

    /// Pins the overlap fix: a second, concurrent extract() call on the SAME instance must not
    /// orphan the first call's continuation/WKWebView (which is what happened when both were
    /// stored as shared instance properties). Both calls share one extractor and one fixture.
    func test_concurrentExtractCallsOnSameInstance_bothSucceed() async throws {
        let html = try fixture("article_basic")
        let extractor = ArticleExtractor(fetch: { _ in html })
        async let first = try extractor.extract(from: XCTUnwrap(URL(string: "https://example.com/terns-1")))
        async let second = try extractor.extract(from: XCTUnwrap(URL(string: "https://example.com/terns-2")))
        let (articleOne, articleTwo) = try await (first, second)
        for article in [articleOne, articleTwo] {
            XCTAssertEqual(article.title, "The Long Migration")
            XCTAssertTrue(article.textContent.contains("Arctic terns"))
        }
    }

    // A hermetic test for the timeout path itself (finding 1) was considered but skipped: there's
    // no way to inject a stalled/hanging WKWebView navigation, so pinning it would mean racing a
    // tiny `timeout:` against real WKWebView init + local-HTML navigation time, which is
    // non-deterministic and would be flaky in CI. The overlap test above covers finding 2, and the
    // cancellation-handler wiring for finding 1 is exercised manually (see fix report).
}
