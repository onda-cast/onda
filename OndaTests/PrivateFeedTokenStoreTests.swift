//  PrivateFeedTokenStoreTests.swift
import XCTest
@testable import Onda

final class PrivateFeedTokenStoreTests: XCTestCase {
    private var store: PrivateFeedTokenStore!

    override func setUp() {
        super.setUp()
        store = PrivateFeedTokenStore(service: "com.chasegilliam.onda.privateFeedTokens.tests")
    }

    override func tearDown() {
        try? store.delete(hash: "hash-a")
        try? store.delete(hash: "hash-b")
        super.tearDown()
    }

    func test_store_thenRealURL_returnsStoredURL() throws {
        let url = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=abc"))
        try store.store(realURL: url, hash: "hash-a")
        XCTAssertEqual(try store.realURL(forHash: "hash-a"), url)
    }

    func test_realURL_forUnknownHash_returnsNil() throws {
        XCTAssertNil(try store.realURL(forHash: "hash-b"))
    }

    func test_store_overwritesExistingValue() throws {
        let first = try XCTUnwrap(URL(string: "https://feeds.example.com/a.xml?token=1"))
        let second = try XCTUnwrap(URL(string: "https://feeds.example.com/a.xml?token=2"))
        try store.store(realURL: first, hash: "hash-a")
        try store.store(realURL: second, hash: "hash-a")
        XCTAssertEqual(try store.realURL(forHash: "hash-a"), second)
    }

    func test_delete_removesEntry() throws {
        let url = try XCTUnwrap(URL(string: "https://feeds.example.com/private.xml?token=abc"))
        try store.store(realURL: url, hash: "hash-a")
        try store.delete(hash: "hash-a")
        XCTAssertNil(try store.realURL(forHash: "hash-a"))
    }
}
