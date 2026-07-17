//  SearchIndex.swift
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SearchDoc: Sendable {
    let kind: String            // "cue" | "clip"
    let episodeGuid: String
    let startTime: TimeInterval
    let body: String
}

struct SearchResult: Identifiable, Sendable, Equatable {
    var id: String { "\(kind)-\(episodeGuid)-\(startTime)" }
    let kind: String
    let episodeGuid: String
    let startTime: TimeInterval
    let snippet: String
}

enum SearchIndexError: Error { case openFailed, sqlError(String) }

@MainActor
final class SearchIndex {
    nonisolated(unsafe) private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SearchIndexError.openFailed
        }
        db = handle
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
              kind UNINDEXED, episode_guid UNINDEXED, start_time UNINDEXED, body
            );
            """)
    }

    nonisolated deinit {
        if let db { sqlite3_close_v2(db) }
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-index.sqlite")
    }

    func upsert(_ doc: SearchDoc) throws {
        try exec("SAVEPOINT upsert;")
        do {
            try delete(kind: doc.kind, episodeGuid: doc.episodeGuid, startTime: doc.startTime)
            let sql = "INSERT INTO search_index (kind, episode_guid, start_time, body) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, doc.kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, doc.episodeGuid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, doc.startTime)
            sqlite3_bind_text(stmt, 4, doc.body, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            try exec("RELEASE upsert;")
        } catch {
            try exec("ROLLBACK TO upsert; RELEASE upsert;")
            throw error
        }
    }

    func delete(kind: String, episodeGuid: String, startTime: TimeInterval) throws {
        let sql = "DELETE FROM search_index WHERE kind = ? AND episode_guid = ? AND start_time = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, episodeGuid, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, startTime)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
    }

    func deleteAll(episodeGuid: String, kind: String) throws {
        let sql = "DELETE FROM search_index WHERE episode_guid = ? AND kind = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, episodeGuid, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
    }

    func search(_ query: String, limit: Int = 50) throws -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let sql = """
            SELECT kind, episode_guid, start_time, snippet(search_index, 3, '', '', '…', 12)
            FROM search_index WHERE search_index MATCH ? ORDER BY bm25(search_index) LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, matchExpression(for: q), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kindC = sqlite3_column_text(stmt, 0),
                  let guidC = sqlite3_column_text(stmt, 1),
                  let snippetC = sqlite3_column_text(stmt, 3) else { continue }
            results.append(SearchResult(kind: String(cString: kindC), episodeGuid: String(cString: guidC),
                                        startTime: sqlite3_column_double(stmt, 2),
                                        snippet: String(cString: snippetC)))
        }
        return results
    }

    func isEmpty() throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM search_index;", -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        return sqlite3_column_int64(stmt, 0) == 0
    }

    func reset() throws { try exec("DELETE FROM search_index;") }

    private func matchExpression(for query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\"*"
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqlError() }
    }

    private func sqlError() -> SearchIndexError {
        .sqlError(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}
