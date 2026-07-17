//  ITunesSearchClient.swift
import Foundation

struct PodcastDTO: Codable, Equatable {
    let collectionId: Int?
    let collectionName: String
    let artistName: String
    let feedUrl: URL?
    let artworkUrl600: URL?
    let primaryGenreName: String?
}

struct ITunesSearchClient: Searching {
    typealias Transport = @Sendable (URL) async throws -> Data
    private let transport: Transport

    init(transport: @escaping Transport = { url in
        try await URLSession.shared.data(from: url).0
    }) {
        self.transport = transport
    }

    // Pure, unit-tested directly.
    func decodeSearch(_ data: Data) throws -> [PodcastDTO] {
        struct Envelope: Codable { let results: [PodcastDTO] }
        return try JSONDecoder().decode(Envelope.self, from: data).results
    }

    func search(term: String) async throws -> [PodcastDTO] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "media", value: "podcast"),
                        .init(name: "entity", value: "podcast"),
                        .init(name: "limit", value: "50"),
                        .init(name: "term", value: term)]
        return try decodeSearch(try await transport(c.url!))
    }

    func lookup(ids: [Int]) async throws -> [PodcastDTO] {
        guard !ids.isEmpty else { return [] }
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [.init(name: "id", value: ids.map(String.init).joined(separator: ",")),
                        .init(name: "entity", value: "podcast")]
        return try decodeSearch(try await transport(c.url!))
    }

    func topChartIds(limit: Int) async throws -> [Int] {
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/\(limit)/podcasts.json")!
        let data = try await transport(url)
        return try JSONDecoder().decode(TopChartsResponse.self, from: data).feed.results.compactMap { Int($0.id) }
    }
}

// Marketing Tools "top charts" response shape — kept file-private and flat (not nested inside
// topChartIds) to stay within SwiftLint's nesting-depth rule.
private struct TopChartsResponse: Codable {
    struct Feed: Codable { let results: [ChartEntry] }
    let feed: Feed
}
private struct ChartEntry: Codable { let id: String }
