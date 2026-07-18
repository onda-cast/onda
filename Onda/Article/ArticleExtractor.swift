//  ArticleExtractor.swift
import Foundation
import WebKit

enum ArticleExtractionError: LocalizedError, Equatable {
    case invalidURL, fetchFailed, noReadableContent, timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That link isn't a valid web address."
        case .fetchFailed: return "Couldn't load the page. Check the link and your connection."
        case .noReadableContent: return "No readable article found on that page."
        case .timeout: return "The page took too long to process."
        }
    }
}

struct ExtractedArticle: Equatable, Sendable {
    var title: String
    var byline: String?
    var siteName: String?
    var textContent: String
}

/// Fetches a URL's HTML and runs Mozilla's Readability.js (Safari-Reader-style extraction)
/// in an off-screen WKWebView. MainActor because WKWebView requires it.
@MainActor
final class ArticleExtractor: NSObject {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private let timeout: Duration
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?   // retained for the duration of one extract() call

    // Readability(document).parse() does NOT return null for a nav-only/chrome-only page — it still
    // returns a low-content object (e.g. textContent "Home", length 4) built from whatever leftover
    // text it could find. A minimum length is required to treat the result as a real article, rather
    // than relying solely on Readability returning null (which it only does when it finds no body at
    // all). 200 characters comfortably separates chrome-only leftovers from real article bodies.
    private static let minReadableTextLength = 200

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         timeout: Duration = .seconds(20)) {
        self.fetch = fetch
        self.timeout = timeout
    }

    func extract(from url: URL) async throws -> ExtractedArticle {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ArticleExtractionError.invalidURL
        }
        let data: Data
        do { data = try await fetch(url) } catch { throw ArticleExtractionError.fetchFailed }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ArticleExtractionError.noReadableContent
        }
        return try await withTimeout { try await self.runReadability(html: html, baseURL: url) }
    }

    private func runReadability(html: String, baseURL: URL) async throws -> ExtractedArticle {
        let web = WKWebView(frame: .zero)
        webView = web
        web.navigationDelegate = self
        defer { webView = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            web.loadHTMLString(html, baseURL: baseURL)
        }
        guard let jsURL = Bundle(for: ArticleExtractor.self).url(forResource: "Readability",
                                                                 withExtension: "js"),
              let readability = try? String(contentsOf: jsURL, encoding: .utf8) else {
            assertionFailure("Readability.js missing from bundle — check project.yml resources")
            throw ArticleExtractionError.noReadableContent
        }
        _ = try? await web.evaluateJavaScript(readability)
        let call = "JSON.stringify(new Readability(document).parse())"
        guard let raw = try? await web.evaluateJavaScript(call) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let dict = obj as? [String: Any],
              let text = (dict["textContent"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= Self.minReadableTextLength else {
            throw ArticleExtractionError.noReadableContent
        }
        return ExtractedArticle(
            title: (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? baseURL.host() ?? "Article",
            byline: dict["byline"] as? String,
            siteName: dict["siteName"] as? String,
            textContent: text)
    }

    private func withTimeout(
        _ op: @escaping @Sendable () async throws -> ExtractedArticle) async throws -> ExtractedArticle {
        try await withThrowingTaskGroup(of: ExtractedArticle.self) { group in
            group.addTask { try await op() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw ArticleExtractionError.timeout
            }
            guard let result = try await group.next() else { throw ArticleExtractionError.timeout }
            group.cancelAll()
            return result
        }
    }
}

extension ArticleExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: ArticleExtractionError.fetchFailed)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        loadContinuation?.resume(throwing: ArticleExtractionError.fetchFailed)
        loadContinuation = nil
    }
}
