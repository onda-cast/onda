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

    func test_entries_appendCreatesZeroAttemptEntriesInOrder() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        let b = URL(string: "https://ex.com/b")!
        q.append(a)
        q.append(b)
        XCTAssertEqual(q.entries(), [PendingArticlesQueue.Entry(url: a, attempts: 0),
                                     PendingArticlesQueue.Entry(url: b, attempts: 0)])
    }

    func test_append_existingURL_preservesAttempts() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        q.append(a)
        q.recordAttempt(a)
        q.append(a)   // re-add (e.g. retry) must not reset the count
        XCTAssertEqual(q.entries(), [PendingArticlesQueue.Entry(url: a, attempts: 1)])
    }

    func test_remove_deletesOnlyThatEntry() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        let b = URL(string: "https://ex.com/b")!
        q.append(a)
        q.append(b)
        q.remove(a)
        XCTAssertEqual(q.entries().map(\.url), [b])
    }

    func test_recordAttempt_incrementsAndPersists() {
        let q = tempQueue()
        let a = URL(string: "https://ex.com/a")!
        q.append(a)
        q.recordAttempt(a)
        q.recordAttempt(a)
        XCTAssertEqual(q.entries().first?.attempts, 2)
        q.recordAttempt(URL(string: "https://ex.com/absent")!)   // no-op, no crash
        XCTAssertEqual(q.entries().count, 1)
    }

    func test_legacyPlainURLArray_decodesAsZeroAttemptEntries() {
        let q = tempQueue()
        let file = q.containerURL!.appendingPathComponent("pending-articles.json")
        try! Data(#"["https://ex.com/old1","https://ex.com/old2"]"#.utf8).write(to: file)
        XCTAssertEqual(q.entries().map(\.url.absoluteString),
                       ["https://ex.com/old1", "https://ex.com/old2"])
        XCTAssertEqual(q.entries().map(\.attempts), [0, 0])
    }

    func test_nilContainer_entriesAndMutationsAreSafeNoOps() {
        let q = PendingArticlesQueue(containerURL: nil)
        q.append(URL(string: "https://ex.com/a")!)
        q.recordAttempt(URL(string: "https://ex.com/a")!)
        q.remove(URL(string: "https://ex.com/a")!)
        XCTAssertEqual(q.entries(), [])
    }
}
