//  ChapterFetcher.swift
import Foundation

struct ParsedChapter { let title: String; let startTime: TimeInterval; let isAd: Bool }

struct ChapterFetcher: Sendable {
    typealias Transport = @Sendable (URL) async throws -> Data
    private let transport: Transport
    init(transport: @escaping Transport = { try await URLSession.shared.data(from: $0).0 }) {
        self.transport = transport
    }

    func decode(_ data: Data) -> [ParsedChapter] {
        guard let doc = try? JSONDecoder().decode(ChaptersDoc.self, from: data) else { return [] }
        return doc.chapters.map { entry in
            let title = entry.title ?? "Chapter"
            let adByTitle = ["ad", "sponsor"].contains { title.lowercased().contains($0) }
            let adByToc = (entry.toc == false)
            return ParsedChapter(title: title, startTime: entry.startTime ?? 0, isAd: adByTitle || adByToc)
        }
    }

    func fetch(_ url: URL) async throws -> [ParsedChapter] { decode(try await transport(url)) }
}

// Podcasting 2.0 <podcast:chapters> JSON shape — kept file-private and flat (not nested inside
// decode) to stay within SwiftLint's nesting-depth rule.
private struct ChaptersDoc: Codable {
    let chapters: [ChapterEntry]
}
private struct ChapterEntry: Codable { let startTime: Double?; let title: String?; let toc: Bool? }
