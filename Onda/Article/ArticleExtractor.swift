//  ArticleExtractor.swift
import Foundation
import WebKit

enum ArticleExtractionError: LocalizedError, Equatable {
    case invalidURL, fetchFailed, noReadableContent, timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: "That link isn't a valid web address."
        case .fetchFailed: "Couldn't load the page. Check the link and your connection."
        case .noReadableContent: "No readable article found on that page."
        case .timeout: "The page took too long to process."
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
///
/// Each `extract(from:)` call creates and owns its own `WKWebView` and `WebLoadDelegate` so that
/// overlapping calls on the same instance never share mutable state (see `runReadability`).
@MainActor
final class ArticleExtractor {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private let timeout: Duration

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
        // Local to this call: a second, concurrent extract() call on the same instance gets its own
        // web view and delegate, so the two never race over shared continuation/webView state.
        let web = WKWebView(frame: .zero)
        let delegate = WebLoadDelegate()
        web.navigationDelegate = delegate   // navigationDelegate is weak — `delegate` above retains it.

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.begin(cont)
                web.loadHTMLString(html, baseURL: baseURL)
            }
        } onCancel: {
            Task { @MainActor in
                web.stopLoading()
                delegate.resume(throwing: ArticleExtractionError.timeout)
            }
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
            textContent: text
        )
    }

    private func withTimeout(
        _ op: @escaping @Sendable () async throws -> ExtractedArticle
    ) async throws -> ExtractedArticle {
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

/// Owns the `CheckedContinuation` for exactly one WKWebView navigation. A single call site
/// (`ArticleExtractor.runReadability`) creates one of these per `extract(from:)` invocation, so
/// concurrent calls never share a continuation. The once-guard lets both the navigation callbacks
/// and the task-cancellation handler race to resume without a double-resume crash.
@MainActor
private final class WebLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    /// Resumes the continuation with `error` (or success if `nil`). Safe to call more than once —
    /// only the first call has any effect — and safe to call from either a navigation delegate
    /// callback or the cancellation handler in `runReadability`.
    func resume(throwing error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        resume()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        resume(throwing: ArticleExtractionError.fetchFailed)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!,
                 withError _: Error) {
        resume(throwing: ArticleExtractionError.fetchFailed)
    }
}
