//  ChapterFetcherTests.swift
import XCTest
@testable import Onda

@MainActor
final class ChapterFetcherTests: XCTestCase {
    func test_decode_parsesChaptersAndFlagsAds() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chapters", withExtension: "json"))
        let chapters = try ChapterFetcher().decode(Data(contentsOf: url))
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters[0].title, "Cold open")
        XCTAssertEqual(chapters[2].startTime, 600)
        XCTAssertTrue(chapters[2].isAd, "toc:false or 'sponsor' title marks an ad")
        XCTAssertFalse(chapters[3].isAd)
    }
}
