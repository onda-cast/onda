//  BookVerifier.swift
//  The gate that makes best-effort trustworthy: a candidate becomes visible ONLY if it
//  fuzzy-matches a real book in OpenLibrary. No match, network failure, or garbled title →
//  dropped silently (precision over recall, per the design spec).
import Foundation

struct VerifiedBook: Equatable, Sendable {
    let workKey: String
    let title: String
    let author: String?
    let coverURL: URL?
}

struct BookVerifier: Sendable {
    typealias Transport = @Sendable (URL) async throws -> Data
    var transport: Transport = { url in try await URLSession.shared.data(from: url).0 }

    static let similarityThreshold = 0.85

    func verify(_ candidate: BookCandidate) async -> VerifiedBook? {
        guard let url = Self.searchURL(for: candidate) else { return nil }
        guard let data = try? await transport(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return nil }
        for doc in docs.prefix(5) {
            guard let key = doc["key"] as? String, let title = doc["title"] as? String else { continue }
            let authors = (doc["author_name"] as? [String]) ?? []
            if let wanted = candidate.title,
               Self.titleSimilarity(wanted, title) < Self.similarityThreshold { continue }
            if let wantedAuthor = candidate.author {
                let lastWord = wantedAuthor.split(separator: " ").last.map(String.init) ?? wantedAuthor
                guard authors.contains(where: { $0.localizedCaseInsensitiveContains(lastWord) })
                else { continue }
            }
            let cover = (doc["cover_i"] as? Int).flatMap {
                URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg")
            }
            return VerifiedBook(workKey: key, title: title, author: authors.first, coverURL: cover)
        }
        return nil
    }

    /// ISBN/ASIN candidates search by identifier; text candidates by title (+author).
    static func searchURL(for candidate: BookCandidate) -> URL? {
        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "limit", value: "5")]
        if let isbn = candidate.isbnOrASIN, isbn.count == 10 || isbn.count == 13 {
            items.append(URLQueryItem(name: "isbn", value: isbn))
        } else if let title = candidate.title, !title.isEmpty {
            items.append(URLQueryItem(name: "title", value: title))
            if let author = candidate.author { items.append(URLQueryItem(name: "author", value: author)) }
        } else {
            return nil   // ASIN-only (non-ISBN) with no title can't be verified — drop
        }
        comps.queryItems = items
        return comps.url
    }

    /// Token-overlap similarity on normalized words, tolerant of dropped subtitles:
    /// the SHORTER title's tokens must nearly all appear in the longer one.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        let hit = short.filter(long.contains).count
        return Double(hit) / Double(short.count)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 || $0 == "a" })
    }
}
