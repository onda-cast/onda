//  BookExtractingContractTests.swift
import XCTest
@testable import Onda

private struct FakeExtractor: BookExtracting {
    var result: [LLMBookCandidate]
    func bookCandidates(transcriptChunks _: [String]) async throws -> [LLMBookCandidate] {
        result
    }
}

final class BookExtractingContractTests: XCTestCase {
    func test_fakeConformsAndRoundTrips() async throws {
        let fake = FakeExtractor(result: [LLMBookCandidate(
            title: "Atomic Habits", author: "James Clear",
            nearbyQuote: "tiny changes remarkable results"
        )])
        let out = try await fake.bookCandidates(transcriptChunks: ["chunk"])
        XCTAssertEqual(out.first?.title, "Atomic Habits")
        XCTAssertEqual(out.first?.nearbyQuote, "tiny changes remarkable results")
    }
}
