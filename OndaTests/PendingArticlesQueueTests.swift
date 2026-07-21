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

    func test_append_dedupesIdenticalURL() throws {
        let q = tempQueue()
        let a = try XCTUnwrap(URL(string: "https://ex.com/a"))
        q.append(a)
        q.append(a)
        XCTAssertEqual(q.entries().map(\.url), [a])
    }

    func test_nilContainer_isSafeNoOp() throws {
        let q = PendingArticlesQueue(containerURL: nil)
        try q.append(XCTUnwrap(URL(string: "https://ex.com/a")))
        XCTAssertEqual(q.entries(), [])
    }

    func test_corruptFile_entriesEmpty() throws {
        let q = tempQueue()
        try q.append(XCTUnwrap(URL(string: "https://ex.com/a")))
        let file = try XCTUnwrap(q.containerURL?.appendingPathComponent("pending-articles.json"))
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(q.entries(), [])
    }

    func test_entries_appendCreatesZeroAttemptEntriesInOrder() throws {
        let q = tempQueue()
        let a = try XCTUnwrap(URL(string: "https://ex.com/a"))
        let b = try XCTUnwrap(URL(string: "https://ex.com/b"))
        q.append(a)
        q.append(b)
        XCTAssertEqual(q.entries(), [PendingArticlesQueue.Entry(url: a, attempts: 0),
                                     PendingArticlesQueue.Entry(url: b, attempts: 0)])
    }

    func test_append_existingURL_preservesAttempts() throws {
        let q = tempQueue()
        let a = try XCTUnwrap(URL(string: "https://ex.com/a"))
        q.append(a)
        q.recordAttempt(a)
        q.append(a)   // re-add (e.g. retry) must not reset the count
        XCTAssertEqual(q.entries(), [PendingArticlesQueue.Entry(url: a, attempts: 1)])
    }

    func test_remove_deletesOnlyThatEntry() throws {
        let q = tempQueue()
        let a = try XCTUnwrap(URL(string: "https://ex.com/a"))
        let b = try XCTUnwrap(URL(string: "https://ex.com/b"))
        q.append(a)
        q.append(b)
        q.remove(a)
        XCTAssertEqual(q.entries().map(\.url), [b])
    }

    func test_recordAttempt_incrementsAndPersists() throws {
        let q = tempQueue()
        let a = try XCTUnwrap(URL(string: "https://ex.com/a"))
        q.append(a)
        q.recordAttempt(a)
        q.recordAttempt(a)
        XCTAssertEqual(q.entries().first?.attempts, 2)
        try q.recordAttempt(XCTUnwrap(URL(string: "https://ex.com/absent")))   // no-op, no crash
        XCTAssertEqual(q.entries().count, 1)
    }

    func test_legacyPlainURLArray_decodesAsZeroAttemptEntries() throws {
        let q = tempQueue()
        let file = try XCTUnwrap(q.containerURL?.appendingPathComponent("pending-articles.json"))
        try Data(#"["https://ex.com/old1","https://ex.com/old2"]"#.utf8).write(to: file)
        XCTAssertEqual(q.entries().map(\.url.absoluteString),
                       ["https://ex.com/old1", "https://ex.com/old2"])
        XCTAssertEqual(q.entries().map(\.attempts), [0, 0])
    }

    func test_nilContainer_entriesAndMutationsAreSafeNoOps() throws {
        let q = PendingArticlesQueue(containerURL: nil)
        try q.append(XCTUnwrap(URL(string: "https://ex.com/a")))
        try q.recordAttempt(XCTUnwrap(URL(string: "https://ex.com/a")))
        try q.remove(XCTUnwrap(URL(string: "https://ex.com/a")))
        XCTAssertEqual(q.entries(), [])
    }
}
