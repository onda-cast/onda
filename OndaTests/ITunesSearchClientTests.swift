//  ITunesSearchClientTests.swift
import XCTest
@testable import Onda

final class ITunesSearchClientTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)!
        return try Data(contentsOf: url)
    }

    func test_decodeSearch_parsesResults_andToleratesMissingFeedUrl() throws {
        let data = try fixture("itunes_search", "json")
        let client = ITunesSearchClient()
        let dtos = try client.decodeSearch(data)
        XCTAssertEqual(dtos.count, 2)
        XCTAssertEqual(dtos[0].collectionName, "The Signal")
        XCTAssertEqual(dtos[0].feedUrl, URL(string: "https://ex.com/signal.xml"))
        XCTAssertNil(dtos[1].feedUrl)  // missing feedUrl decodes as nil, not an error
    }

    func test_search_usesInjectedTransport_andEncodesTerm() async throws {
        let data = try fixture("itunes_search", "json")
        var requestedURL: URL?
        let client = ITunesSearchClient(transport: { url in requestedURL = url; return data })
        let dtos = try await client.search(term: "slow burn")
        XCTAssertEqual(dtos.count, 2)
        XCTAssertTrue(requestedURL?.absoluteString.contains("term=slow%20burn") ?? false)
        XCTAssertTrue(requestedURL?.absoluteString.contains("media=podcast") ?? false)
    }
}
