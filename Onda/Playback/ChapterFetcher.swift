//  ChapterFetcher.swift
import Foundation

struct ParsedChapter { let title: String; let startTime: TimeInterval; let isAd: Bool; var source = "feed" }

struct ChapterFetcher: Sendable {
    typealias Transport = @Sendable (URL) async throws -> Data
    private let transport: Transport
    init(transport: @escaping Transport = { try await URLSession.shared.data(from: $0).0 }) {
        self.transport = transport
    }

    func decode(_ data: Data) -> [ParsedChapter] {
        struct Doc: Codable {
            struct Ch: Codable { let startTime: Double?; let title: String?; let toc: Bool? }
            let chapters: [Ch]
        }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return [] }
        return doc.chapters.map { c in
            let title = c.title ?? "Chapter"
            let adByTitle = ["ad", "sponsor"].contains { title.lowercased().contains($0) }
            let adByToc = (c.toc == false)
            return ParsedChapter(title: title, startTime: c.startTime ?? 0, isAd: adByTitle || adByToc)
        }
    }

    func fetch(_ url: URL) async throws -> [ParsedChapter] { decode(try await transport(url)) }
}
