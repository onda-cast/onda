//  PrivateFeedIdentityTests.swift
import XCTest
@testable import Onda

final class PrivateFeedIdentityTests: XCTestCase {
    func test_hash_isDeterministic() throws {
        let url = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=abc"))
        XCTAssertEqual(PrivateFeedIdentity.hash(for: url), PrivateFeedIdentity.hash(for: url))
    }

    func test_hash_differsForDifferentURLs() throws {
        let a = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=abc"))
        let b = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=xyz"))
        XCTAssertNotEqual(PrivateFeedIdentity.hash(for: a), PrivateFeedIdentity.hash(for: b))
    }

    func test_placeholderURL_usesPlaceholderSchemeAndHash() {
        let hash = "abc123"
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        XCTAssertEqual(placeholder.scheme, "onda-private-feed")
        XCTAssertEqual(placeholder.host, hash)
    }

    func test_isPlaceholder_trueForPlaceholder_falseForRealURL() throws {
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: "abc123")
        let real = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=abc"))
        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(placeholder))
        XCTAssertFalse(PrivateFeedIdentity.isPlaceholder(real))
    }
}
