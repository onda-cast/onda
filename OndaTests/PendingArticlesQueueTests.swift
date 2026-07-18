//  PendingArticlesQueueTests.swift
// swiftlint:disable force_try
import XCTest
@testable import Onda

final class PendingArticlesQueueTests: XCTestCase {
    private func tempQueue() -> PendingArticlesQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingArticlesQueue(containerURL: dir)
    }

    func test_appendThenDrain_returnsURLsInOrderAndClears() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        let b = URL(string: "https://ex.com/b")!
        q.append(a)
        q.append(b)
        XCTAssertEqual(q.drain(), [a, b])
        XCTAssertEqual(q.drain(), [], "drain must clear the file")
    }

    func test_append_dedupesIdenticalURL() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        q.append(a)
        q.append(a)
        XCTAssertEqual(q.drain(), [a])
    }

    func test_nilContainer_isSafeNoOp() {
        let q = PendingArticlesQueue(containerURL: nil)
        q.append(URL(string: "https://ex.com/a")!)
        XCTAssertEqual(q.drain(), [])
    }

    func test_corruptFile_drainsEmpty() {
        let q = tempQueue()
        q.append(URL(string: "https://ex.com/a")!)
        let file = q.containerURL!.appendingPathComponent("pending-articles.json")
        try! Data("not json".utf8).write(to: file)
        XCTAssertEqual(q.drain(), [])
    }
}
