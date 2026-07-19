//  BookLinkParser.swift
//  Tier 1: book-retailer URLs from show notes — the highest-precision candidate source.
import Foundation

enum BookLinkParser {
    static func candidates(from links: [URL]) -> [BookCandidate] {
        links.compactMap { candidate(from: $0) }
    }

    private static func candidate(from url: URL) -> BookCandidate? {
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.contains("amazon.") {
            // /dp/<ASIN> or /gp/product/<ASIN>
            if let i = parts.firstIndex(of: "dp"), parts.indices.contains(i + 1) {
                return BookCandidate(title: nil, author: nil, isbnOrASIN: parts[i + 1],
                                     timestamp: nil, sourceTier: "link")
            }
            if let i = parts.firstIndex(of: "product"), parts.indices.contains(i + 1),
               i > 0, parts[i - 1] == "gp" {
                return BookCandidate(title: nil, author: nil, isbnOrASIN: parts[i + 1],
                                     timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        if host.contains("bookshop.org") {
            // /p/books/<title-slug>/<id>
            if let i = parts.firstIndex(of: "books"), parts.indices.contains(i + 1) {
                return BookCandidate(title: slugWords(parts[i + 1]), author: nil,
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        if host.contains("goodreads.com") {
            // /book/show/<id>-<title-slug>
            if let i = parts.firstIndex(of: "show"), parts.indices.contains(i + 1) {
                let slug = parts[i + 1].drop { $0.isNumber || $0 == "-" }
                guard !slug.isEmpty else { return nil }
                return BookCandidate(title: slugWords(String(slug)), author: nil,
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "link")
            }
            return nil
        }
        return nil
    }

    private static func slugWords(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
