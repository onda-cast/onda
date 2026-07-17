# Onda Plan 11: FTS5 Full-Library Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain SwiftData-predicate transcript search with a real full-text index (SQLite FTS5) covering both transcript cues and personal clips together, with relevance ranking and in-context snippets — while staying 100% on-device.

**Architecture — one refinement vs. the spec's wording:** the v0.6 spec described this as "the same on-disk store SwiftData already uses." On reflection, SwiftData's own store is a Core Data-managed SQLite file with an opaque, private schema — attaching FTS5 tables directly into it is unsupported and risks corruption. Instead, `SearchIndex` owns a **separate sidecar SQLite database** (`search-index.sqlite` in Application Support) dedicated to the search index, opened directly via the C `sqlite3` API (no external dependency — `SQLite3` is a system module). It's still fully on-device/private, just decoupled from SwiftData's internal storage; a nice side effect is that it needs no SwiftData schema migration at all. `TranscriptService` and `ClipService` keep it in sync on write; `TranscriptSearch` becomes a thin query layer over it, resolving hits back to SwiftData objects for navigation.

**Tech Stack:** Swift 6, SwiftData, SQLite3 (FTS5), XCTest.

## Global Constraints

- Plan 1 Global Constraints apply verbatim (iOS 17, SwiftUI+SwiftData only, MV pattern, brutal style).
- No network calls — the index is a local file, built and queried entirely on-device.
- `SearchIndex` is `@MainActor`-only (matches every other service in this codebase) — no attempt at background-thread sqlite access, since this is a single-user app with no concurrent-write pressure.
- `TranscriptService`/`ClipService` take the new `SearchIndex?` dependency as an **optional parameter defaulting to `nil`**, so every existing test call site from Plans 6–7 keeps compiling unchanged; only new tests exercise the indexing path.

**Depends on:** Plans 1–7 merged (v0.3.0+) for `TranscriptCue`/`Clip`/`TranscriptService`/`ClipService`/`TranscriptSearch`. Independent of Plans 8, 9, 10.

---

## File Structure

```
Onda/
  Search/
    SearchIndex.swift          — NEW: sidecar FTS5 db wrapper
    SearchIndexBox.swift        — NEW: @Observable environment box (mirrors ITunesSearchClientBox)
  Transcription/
    TranscriptService.swift     — MODIFY: index cues on persist
    TranscriptSearch.swift      — MODIFY: query SearchIndex instead of a SwiftData predicate
  Clips/
    ClipService.swift           — MODIFY: index/reindex/delete clips; new updateNote(_:note:)
    ClipEditSheet.swift         — MODIFY: route existing-clip note edits through updateNote
  Library/
    LibrarySearchView.swift     — MODIFY: pass SearchIndexBox through to TranscriptSearch
  OndaApp.swift                 — MODIFY: build SearchIndex, inject, one-time backfill
project.yml                     — MODIFY: link libsqlite3.tbd
OndaTests/
  SearchIndexTests.swift
  TranscriptServiceTests.swift  — MODIFY: indexing test
  ClipServiceTests.swift        — MODIFY: indexing tests
  TranscriptSearchTests.swift   — MODIFY: rewritten against SearchIndex
```

---

### Task 0: Link `libsqlite3.tbd`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1:** Add `dependencies: [{ sdk: libsqlite3.tbd }]` under the `Onda` target:

```yaml
  Onda:
    type: application
    platform: iOS
    sources: [Onda]
    dependencies:
      - sdk: libsqlite3.tbd
```

(Insert the new `dependencies:` key right after `sources: [Onda]`, before `info:`.)

- [ ] **Step 2:** Run `xcodegen generate -q` and confirm it completes without error.
- [ ] **Step 3: Commit** — `git add project.yml && git commit -m "build: link libsqlite3 for FTS5 search index"`

---

### Task 1: `SearchIndex` (sidecar FTS5 database)

**Files:**
- Create: `Onda/Search/SearchIndex.swift`
- Test: `OndaTests/SearchIndexTests.swift`

**Interfaces:**
- Produces:
  - `struct SearchDoc: Sendable { let kind: String; let episodeGuid: String; let startTime: TimeInterval; let body: String }` (`kind` is `"cue"` or `"clip"`)
  - `struct SearchResult: Identifiable, Sendable { var id: String; let kind: String; let episodeGuid: String; let startTime: TimeInterval; let snippet: String }`
  - `enum SearchIndexError: Error { case openFailed, sqlError(String) }`
  - `@MainActor final class SearchIndex`
    - `init(path: String) throws`
    - `static func defaultFileURL() -> URL`
    - `func upsert(_ doc: SearchDoc) throws`
    - `func delete(kind: String, episodeGuid: String, startTime: TimeInterval) throws`
    - `func deleteAll(episodeGuid: String, kind: String) throws`
    - `func search(_ query: String, limit: Int = 50) throws -> [SearchResult]`
    - `func isEmpty() throws -> Bool`
    - `func reset() throws`

- [ ] **Step 1: Write failing tests**

`OndaTests/SearchIndexTests.swift`:

```swift
//  SearchIndexTests.swift
import XCTest
@testable import Onda

@MainActor
final class SearchIndexTests: XCTestCase {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(path: ":memory:")
    }

    func test_upsertAndSearch_findsMatchingBody_withSnippet() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 10,
                                 body: "the slow death of the homepage"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 40,
                                 body: "octopus cognition is wild"))
        let hits = try idx.search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.episodeGuid, "g1")
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertTrue(hits.first?.snippet.localizedCaseInsensitiveContains("homepage") ?? false)
    }

    func test_search_ranksMoreRelevantMatchHigher() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "a", startTime: 0, body: "swift swift swift language"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "b", startTime: 0, body: "swift is nice"))
        let hits = try idx.search("swift")
        XCTAssertEqual(hits.first?.episodeGuid, "a", "denser match should rank first")
    }

    func test_delete_removesExactDoc() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "remember this insight"))
        try idx.delete(kind: "clip", episodeGuid: "g1", startTime: 5)
        XCTAssertTrue(try idx.search("insight").isEmpty)
    }

    func test_deleteAll_removesOnlyMatchingKindAndEpisode() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "alpha"))
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 0, body: "alpha note"))
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g2", startTime: 0, body: "alpha too"))
        try idx.deleteAll(episodeGuid: "g1", kind: "cue")
        let hits = try idx.search("alpha")
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g1" && $0.kind == "cue" }.count, 0)
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g1" && $0.kind == "clip" }.count, 1)
        XCTAssertEqual(hits.filter { $0.episodeGuid == "g2" }.count, 1)
    }

    func test_upsert_replacesExistingDocAtSameKey() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "first note"))
        try idx.upsert(SearchDoc(kind: "clip", episodeGuid: "g1", startTime: 5, body: "second note"))
        let hits = try idx.search("note")
        XCTAssertEqual(hits.count, 1, "second upsert replaces, doesn't duplicate")
        XCTAssertTrue(hits.first!.snippet.localizedCaseInsensitiveContains("second"))
    }

    func test_isEmpty_trueUntilFirstInsert() throws {
        let idx = try makeIndex()
        XCTAssertTrue(try idx.isEmpty())
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "hello"))
        XCTAssertFalse(try idx.isEmpty())
    }

    func test_search_shortQuery_returnsEmpty() throws {
        let idx = try makeIndex()
        try idx.upsert(SearchDoc(kind: "cue", episodeGuid: "g1", startTime: 0, body: "hello world"))
        XCTAssertEqual(try idx.search("h"), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/SearchIndexTests`
Expected: FAIL — `cannot find 'SearchIndex' in scope`.

- [ ] **Step 3: Implement**

```swift
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
    private var db: OpaquePointer?

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

    deinit { if let db { sqlite3_close(db) } }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-index.sqlite")
    }

    func upsert(_ doc: SearchDoc) throws {
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
        let q = query.trimmingCharacters(in: .whitespaces)
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
```

- [ ] **Step 4: Run to verify pass** — Expected: all 7 `SearchIndexTests` PASS.
- [ ] **Step 5: Commit** — `git add Onda/Search OndaTests/SearchIndexTests.swift && git commit -m "feat: SearchIndex, a sidecar SQLite FTS5 index for transcript cues and clips"`

---

### Task 2: Index cues and clips on write

**Files:**
- Modify: `Onda/Transcription/TranscriptService.swift`, `Onda/Clips/ClipService.swift`, `Onda/Clips/ClipEditSheet.swift`
- Test: `OndaTests/TranscriptServiceTests.swift`, `OndaTests/ClipServiceTests.swift`

**Interfaces:**
- `TranscriptService.init(modelContext:parser:engine:fetch:localURL:index: SearchIndex? = nil)`. `persist(cues:for:source:)` clears any existing cue docs for the episode (`index?.deleteAll(episodeGuid:kind: "cue")`) then upserts one `SearchDoc(kind: "cue", ...)` per cue.
- `ClipService.init(modelContext:index: SearchIndex? = nil)`. `makeClip` upserts a `SearchDoc(kind: "clip", episodeGuid: episode.guid, startTime: clip.startTime, body: [clip.text, clip.note].compactMap { $0 }.joined(separator: " "))` after saving. `delete(_:)` calls `index?.delete(kind: "clip", episodeGuid:startTime:)` for the deleted clip. New `func updateNote(_ clip: Clip, note: String?)` — sets `clip.note`/`needsReview = false`, saves, then re-upserts the clip's search doc (note changed → body changed). `ClipEditSheet.save()`'s `existing` branch now calls `clips.updateNote(existing, note: note.isEmpty ? nil : note)` instead of mutating fields directly.

- [ ] **Step 1: Write failing tests**

Append to `OndaTests/TranscriptServiceTests.swift`:

```swift
    func test_persist_indexesCuesForSearch() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let index = try SearchIndex(path: ":memory:")
        let svc = TranscriptService(modelContext: ctx, engine: nil, fetch: { _ in Data() },
                                    localURL: { _ in nil }, index: index)
        let cues = [ParsedCue(startTime: 0, endTime: 2, text: "octopus cognition is wild", speaker: nil)]
        _ = svc.persist(cues: cues, for: ep, source: "published")
        let hits = try index.search("octopus")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.episodeGuid, "g")
    }

    func test_persist_reindexing_clearsStaleCuesForSameEpisode() throws {
        let ctx = try makeContext()
        let ep = episode(in: ctx, transcriptURL: nil)
        let index = try SearchIndex(path: ":memory:")
        let svc = TranscriptService(modelContext: ctx, engine: nil, fetch: { _ in Data() },
                                    localURL: { _ in nil }, index: index)
        _ = svc.persist(cues: [ParsedCue(startTime: 0, endTime: 2, text: "first version", speaker: nil)],
                        for: ep, source: "published")
        _ = svc.persist(cues: [ParsedCue(startTime: 0, endTime: 2, text: "second version", speaker: nil)],
                        for: ep, source: "published")
        XCTAssertTrue(try index.search("first").isEmpty)
        XCTAssertEqual(try index.search("second").count, 1)
    }
```

Append to `OndaTests/ClipServiceTests.swift`:

```swift
    func test_makeClip_indexesTextAndNote() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10,
                                note: "remember this", needsReview: false)
        let byText = try index.search("alpha")
        let byNote = try index.search("remember")
        XCTAssertEqual(byText.first?.startTime, clip.startTime)
        XCTAssertEqual(byNote.count, 1)
    }

    func test_updateNote_reindexesWithNewNote() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10, note: "old note", needsReview: true)
        svc.updateNote(clip, note: "new note")
        XCTAssertEqual(clip.note, "new note")
        XCTAssertFalse(clip.needsReview)
        XCTAssertTrue(try index.search("old").isEmpty)
        XCTAssertEqual(try index.search("new note").count, 1)
    }

    func test_delete_removesFromIndex() throws {
        let (ctx, ep) = try env()
        let index = try SearchIndex(path: ":memory:")
        let svc = ClipService(modelContext: ctx, index: index)
        let clip = svc.makeClip(episode: ep, requestedStart: 0, requestedEnd: 10, note: "findable", needsReview: false)
        svc.delete(clip)
        XCTAssertTrue(try index.search("findable").isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure** — Expected: `extra argument 'index' in call` for both services.

- [ ] **Step 3: Implement**

`TranscriptService` changes — add the stored property and parameter:

```swift
    private let index: SearchIndex?

    init(modelContext: ModelContext, parser: TranscriptParser = .init(),
         engine: AudioTranscribing?,
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         localURL: @escaping (Episode) -> URL?,
         index: SearchIndex? = nil) {
        self.modelContext = modelContext
        self.parser = parser
        self.engine = engine
        self.fetch = fetch
        self.localURL = localURL
        self.index = index
    }
```

In `persist(cues:for:source:)`, after `tr.cues = built` and before `try? modelContext.save()`:

```swift
        tr.cues = built
        if let index {
            try? index.deleteAll(episodeGuid: episode.guid, kind: "cue")
            for cue in built {
                try? index.upsert(SearchDoc(kind: "cue", episodeGuid: episode.guid,
                                            startTime: cue.startTime, body: cue.text))
            }
        }
        try? modelContext.save()
```

`ClipService` changes:

```swift
    private let index: SearchIndex?

    init(modelContext: ModelContext, index: SearchIndex? = nil) {
        self.modelContext = modelContext
        self.index = index
    }

    @discardableResult
    func makeClip(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval,
                  note: String?, needsReview: Bool) -> Clip {
        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { (start: $0.startTime, end: $0.endTime, text: $0.text) }
        let snapped = ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                            requestedEnd: requestedEnd)
        let clip = Clip(startTime: snapped.start, endTime: snapped.end, text: snapped.text,
                        note: note, createdAt: .now, needsReview: needsReview)
        clip.episode = episode
        episode.clips.append(clip)
        modelContext.insert(clip)
        try? modelContext.save()
        reindex(clip)
        return clip
    }

    func updateNote(_ clip: Clip, note: String?) {
        clip.note = note
        clip.needsReview = false
        try? modelContext.save()
        reindex(clip)
    }

    func delete(_ clip: Clip) {
        if let guid = clip.episode?.guid {
            try? index?.delete(kind: "clip", episodeGuid: guid, startTime: clip.startTime)
        }
        clip.episode?.clips.removeAll { $0 === clip }
        modelContext.delete(clip)
        try? modelContext.save()
    }

    private func reindex(_ clip: Clip) {
        guard let index, let guid = clip.episode?.guid else { return }
        let body = [clip.text, clip.note].compactMap { $0 }.joined(separator: " ")
        try? index.upsert(SearchDoc(kind: "clip", episodeGuid: guid, startTime: clip.startTime, body: body))
    }
```

(`quickClip`, `allClips`, `search` are unchanged.)

`ClipEditSheet.save()` — replace the `existing` branch:

```swift
    private func save() {
        if let existing {
            clips.updateNote(existing, note: note.isEmpty ? nil : note)
        } else if let episode {
            clips.makeClip(episode: episode, requestedStart: requestedStart,
                           requestedEnd: requestedEnd,
                           note: note.isEmpty ? nil : note, needsReview: false)
        }
        dismiss()
    }
```

- [ ] **Step 4: Run to verify pass** — Expected: all `TranscriptServiceTests` + `ClipServiceTests` PASS (existing tests still pass unchanged since `index` defaults to `nil`).
- [ ] **Step 5: Commit** — `"feat: index transcript cues and clips into SearchIndex on write"`

---

### Task 3: `TranscriptSearch` over `SearchIndex`; app wiring + backfill

**Files:**
- Modify: `Onda/Transcription/TranscriptSearch.swift`, `Onda/Library/LibrarySearchView.swift`, `Onda/OndaApp.swift`
- Create: `Onda/Search/SearchIndexBox.swift`
- Test: `OndaTests/TranscriptSearchTests.swift` (rewritten)

**Interfaces:**
- `TranscriptHit` gains `kind: String` ("cue" | "clip"); `id` becomes `kind + "-" + episodeGuid + "-\(startTime)"`.
- `TranscriptSearch.init(modelContext:index:)`; `search(_:)` queries `index.search(_:)`, resolves each hit's `episodeGuid` to an `Episode` via a SwiftData fetch, and drops any hit whose episode is missing or unsubscribed (same subscribed-only filter as before).
- `@MainActor @Observable final class SearchIndexBox { let index: SearchIndex }` (same shape as `ITunesSearchClientBox`).
- `LibrarySearchView` reads `@Environment(SearchIndexBox.self) private var searchIndexBox` and calls `TranscriptSearch(modelContext: modelContext, index: searchIndexBox.index).search(q)`.
- `OndaApp` builds one `SearchIndex` at `SearchIndex.defaultFileURL().path`, wraps it in `SearchIndexBox`, passes it into `TranscriptService`/`ClipService`, injects the box, and — if `index.isEmpty()` — runs a one-time backfill over every existing `TranscriptCue`/`Clip` already in SwiftData (covers upgrades from before this plan shipped).

- [ ] **Step 1: Write failing tests** (rewrite `OndaTests/TranscriptSearchTests.swift`)

```swift
//  TranscriptSearchTests.swift
import XCTest
import SwiftData
@testable import Onda

@MainActor
final class TranscriptSearchTests: XCTestCase {
    func test_search_findsMatchingCues_inSubscribedShows() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "g", startTime: 10,
                                   body: "the slow death of the homepage"))

        let hits = TranscriptSearch(modelContext: ctx, index: index).search("homepage")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startTime, 10)
        XCTAssertEqual(hits.first?.showTitle, "The Signal")
        XCTAssertEqual(hits.first?.kind, "cue")
    }

    func test_search_excludesUnsubscribedShows() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: false)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "cue", episodeGuid: "g", startTime: 10, body: "homepage"))

        XCTAssertTrue(TranscriptSearch(modelContext: ctx, index: index).search("homepage").isEmpty)
    }

    func test_search_includesClipHits() throws {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let index = try SearchIndex(path: ":memory:")
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "The Signal", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1, isSubscribed: true)
        let ep = Episode(guid: "g", title: "Ep 1", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        try index.upsert(SearchDoc(kind: "clip", episodeGuid: "g", startTime: 20, body: "a great insight"))

        let hits = TranscriptSearch(modelContext: ctx, index: index).search("insight")
        XCTAssertEqual(hits.first?.kind, "clip")
    }
}
```

- [ ] **Step 2: Run to verify failure** — Expected: `extra argument 'index' in call` / `no member 'kind'`.

- [ ] **Step 3: Implement**

`Onda/Search/SearchIndexBox.swift`:

```swift
//  SearchIndexBox.swift
import Foundation

@MainActor
@Observable
final class SearchIndexBox {
    let index: SearchIndex
    init(index: SearchIndex) { self.index = index }
}
```

`Onda/Transcription/TranscriptSearch.swift`:

```swift
//  TranscriptSearch.swift
import Foundation
import SwiftData

struct TranscriptHit: Identifiable {
    var id: String { kind + "-" + episodeGuid + "-\(startTime)" }
    let kind: String            // "cue" | "clip"
    let episodeGuid: String
    let episodeTitle: String
    let showTitle: String
    let cueText: String
    let startTime: TimeInterval
}

@MainActor
struct TranscriptSearch {
    private let modelContext: ModelContext
    private let index: SearchIndex
    init(modelContext: ModelContext, index: SearchIndex) {
        self.modelContext = modelContext
        self.index = index
    }

    func search(_ query: String) -> [TranscriptHit] {
        let results = (try? index.search(query)) ?? []
        return results.compactMap { r -> TranscriptHit? in
            let guid = r.episodeGuid
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            guard let ep = (try? modelContext.fetch(descriptor))?.first,
                  let pod = ep.podcast, pod.isSubscribed else { return nil }
            return TranscriptHit(kind: r.kind, episodeGuid: ep.guid, episodeTitle: ep.title,
                                 showTitle: pod.title, cueText: r.snippet, startTime: r.startTime)
        }
    }
}
```

`Onda/Library/LibrarySearchView.swift` — add the environment and update the call site:

```swift
    @Environment(SearchIndexBox.self) private var searchIndexBox
```

```swift
            .onChange(of: query) { _, q in
                hits = TranscriptSearch(modelContext: modelContext, index: searchIndexBox.index).search(q)
            }
```

`Onda/OndaApp.swift` — build the index, wire both services, inject the box, backfill once:

```swift
            let index = try SearchIndex(path: SearchIndex.defaultFileURL().path)
            let searchBox = SearchIndexBox(index: index)
            _searchIndexBox = State(initialValue: searchBox)
```

(add `@State private var searchIndexBox: SearchIndexBox` as a property), pass `index: index` into the existing `TranscriptService(...)` and `ClipService(modelContext: c.mainContext)` constructions, add `.environment(searchIndexBox)` in `body`, and after `UITestSeed.seed(context: c.mainContext)` add a one-time backfill:

```swift
            if (try? index.isEmpty()) == true {
                let cues = (try? c.mainContext.fetch(FetchDescriptor<TranscriptCue>())) ?? []
                for cue in cues {
                    guard let guid = cue.transcript?.episode?.guid else { continue }
                    try? index.upsert(SearchDoc(kind: "cue", episodeGuid: guid,
                                                startTime: cue.startTime, body: cue.text))
                }
                let clips = (try? c.mainContext.fetch(FetchDescriptor<Clip>())) ?? []
                for clip in clips {
                    guard let guid = clip.episode?.guid else { continue }
                    let body = [clip.text, clip.note].compactMap { $0 }.joined(separator: " ")
                    try? index.upsert(SearchDoc(kind: "clip", episodeGuid: guid,
                                                startTime: clip.startTime, body: body))
                }
            }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodegen generate -q && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, all tests PASS (full suite, including rewritten `TranscriptSearchTests`).

- [ ] **Step 5: Commit** — `"feat: TranscriptSearch backed by FTS5 SearchIndex; covers cues and clips; one-time backfill"`

---

### Task 4: Regression + smoke + tag

- [ ] **Step 1:** Full suite: expect all prior tests (Plans 1–10) + new `SearchIndexTests`/updated `TranscriptSearchTests` green.
- [ ] **Step 2:** Manual smoke (user): Library search for a word that appears in a transcript AND a clip note — confirm both kinds of hits appear, ranked, with in-context snippets; edit a clip's note to a new word and confirm the old note text stops matching and the new one does; delete a clip and confirm it drops out of search immediately.
- [ ] **Step 3:** Merge per finishing-a-development-branch; tag `v0.6.0`.

---

## Self-Review

- **Spec coverage:** FTS5-backed index covering cues + clips together ✓; BM25 ranking + snippets ✓; sync on cue persist / clip create-edit-delete ✓; becomes the backing for the existing Library search screen ✓. The one deliberate deviation from the spec's literal wording ("same on-disk store") is called out up front with the reasoning, not silently changed.
- **Placeholder scan:** none — full code in every step, including the raw sqlite3 C interop (a common, standard idiom, not hand-waved).
- **Type consistency:** `SearchDoc`/`SearchResult`/`SearchIndex.upsert/delete/deleteAll/search/isEmpty/reset`, `TranscriptService(..., index:)`, `ClipService(..., index:)`/`updateNote`, `TranscriptHit.kind`, `TranscriptSearch.init(modelContext:index:)` used identically across all three tasks.
