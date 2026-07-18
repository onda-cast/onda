//  PrivateFeedIdentityTests.swift
import XCTest
@testable import Onda

final class PrivateFeedIdentityTests: XCTestCase {
    func test_hash_isDeterministic() {
        let url = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        XCTAssertEqual(PrivateFeedIdentity.hash(for: url), PrivateFeedIdentity.hash(for: url))
    }

    func test_hash_differsForDifferentURLs() {
        let a = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        let b = URL(string: "https://feeds.example.com/private.xml?token=xyz")!
        XCTAssertNotEqual(PrivateFeedIdentity.hash(for: a), PrivateFeedIdentity.hash(for: b))
    }

    func test_placeholderURL_usesPlaceholderSchemeAndHash() {
        let hash = "abc123"
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: hash)
        XCTAssertEqual(placeholder.scheme, "onda-private-feed")
        XCTAssertEqual(placeholder.host, hash)
    }

    func test_isPlaceholder_trueForPlaceholder_falseForRealURL() {
        let placeholder = PrivateFeedIdentity.placeholderURL(forHash: "abc123")
        let real = URL(string: "https://feeds.example.com/private.xml?token=abc")!
        XCTAssertTrue(PrivateFeedIdentity.isPlaceholder(placeholder))
        XCTAssertFalse(PrivateFeedIdentity.isPlaceholder(real))
    }
}
