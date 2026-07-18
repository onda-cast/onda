# Article Background Conversion Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Article conversions survive app suspension and termination: a persistent queue is the source of truth, in-flight work continues briefly after backgrounding, and a `BGProcessingTask` drains the queue opportunistically.

**Architecture:** `PendingArticlesQueue` becomes the durable record (`[{url, attempts}]` JSON, legacy-format tolerant) shared with the share extension. `ArticleConversionService` writes to it on add, removes on success/dismiss, increments attempts on failure, and reconciles on foreground. Each conversion wraps itself in `UIApplication.beginBackgroundTask`; a new `BGProcessingTask` (`com.onda.articles.convert`) processes remaining entries, following `FeedRefreshService`'s registration pattern.

**Tech Stack:** Foundation (JSON queue), BackgroundTasks, UIKit (background task continuation), os.Logger.

**Spec:** `docs/superpowers/specs/2026-07-17-article-podcast-apple-tts-design.md` — "Addendum: Background conversion pipeline".

## Global Constraints

- Swift 6 (`SWIFT_VERSION: "6.0"`), deployment target iOS 17.0. SwiftLint max line length 150.
- `Onda.xcodeproj` is generated — after editing `project.yml` or adding files, run `xcodegen generate`.
- Test command: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/<ClassName>` (if the shared sim flakes with foreign-bundle errors, use a dedicated simulator per `.claude/skills/verify/SKILL.md`).
- `PendingArticlesQueue.swift` is compiled into BOTH the app and OndaShareExtension targets — it must stay Foundation-only.
- Auto-retry cap: `attempts < 3` converts automatically; at/over cap requires manual RETRY.
- Episodes are inserted only on full success; cancellation/expiry must leave the queue entry in place (only success and user-dismiss remove it).
- `processQueueForBackground()` must never start a conversion for a URL with an in-flight attempt (`inFlight[url] != nil`) — a suspended foreground conversion resumes alongside a background wake, and direct `convert` on an in-flight URL can duplicate episodes.

---

### Task 1: PendingArticlesQueue v2 — persistent entries with attempts

**Files:**
- Modify: `Onda/Article/PendingArticlesQueue.swift`
- Test: `OndaTests/PendingArticlesQueueTests.swift` (extend; existing tests updated where semantics changed)

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 2-3 rely on these exact names):
  - `struct PendingArticlesQueue.Entry: Codable, Equatable, Sendable { var url: URL; var attempts: Int }`
  - `func append(_ url: URL)` (unchanged signature; appends `Entry(url: url, attempts: 0)`, dedupes by url — preserving an existing entry's attempts)
  - `func entries() -> [Entry]` (read-only, in insertion order)
  - `func remove(_ url: URL)`
  - `func recordAttempt(_ url: URL)` (increments `attempts` for that url; no-op if absent)
  - `func drain() -> [URL]` REMAINS for now (Task 2 deletes it with its last caller).
  - Legacy tolerance: a file containing the old `[URL]` array decodes as entries with `attempts: 0`. Corrupt files decode as empty (existing behavior).

- [ ] **Step 1: Write the failing tests**

In `OndaTests/PendingArticlesQueueTests.swift`, add (keeping the existing `tempQueue()` helper and tests; `test_appendThenDrain_returnsURLsInOrderAndClears` and `test_corruptFile_drainsEmpty` stay valid because `drain()` survives this task):

```swift
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/PendingArticlesQueueTests`
Expected: BUILD FAILURE — `Entry`/`entries`/`remove`/`recordAttempt` not found.

- [ ] **Step 3: Implement**

Replace the storage layer of `Onda/Article/PendingArticlesQueue.swift` (keep the header comment, `appGroupID`, `standard`, `containerURL`, `fileURL`):

```swift
    struct Entry: Codable, Equatable, Sendable {
        var url: URL
        var attempts: Int
    }

    func append(_ url: URL) {
        guard fileURL != nil else { return }
        var all = loadEntries()
        guard !all.contains(where: { $0.url == url }) else { return }
        all.append(Entry(url: url, attempts: 0))
        save(all)
    }

    func entries() -> [Entry] {
        loadEntries()
    }

    func remove(_ url: URL) {
        guard fileURL != nil else { return }
        save(loadEntries().filter { $0.url != url })
    }

    func recordAttempt(_ url: URL) {
        guard fileURL != nil else { return }
        var all = loadEntries()
        guard let i = all.firstIndex(where: { $0.url == url }) else { return }
        all[i].attempts += 1
        save(all)
    }

    /// Transitional: read-and-clear used by the pre-persistent-queue foreground drain.
    /// Deleted in the service-integration task along with its last caller.
    func drain() -> [URL] {
        guard let fileURL else { return [] }
        let urls = loadEntries().map(\.url)
        try? FileManager.default.removeItem(at: fileURL)
        return urls
    }

    private func loadEntries() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        // Legacy format: a plain [URL] array from the drain-once era.
        if let urls = try? JSONDecoder().decode([URL].self, from: data) {
            return urls.map { Entry(url: $0, attempts: 0) }
        }
        return []
    }

    private func save(_ entries: [Entry]) {
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
```

- [ ] **Step 4: Run tests to verify all pass**

Run: same command.
Expected: PASS (existing 4 + new 6). Note `test_appendThenDrain_returnsURLsInOrderAndClears` still passes (drain maps entries to URLs).

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/PendingArticlesQueue.swift OndaTests/PendingArticlesQueueTests.swift
git commit -m "feat: pending-articles queue v2 — attempt-counted entries, legacy-format decode"
```

---

### Task 2: ArticleConversionService — persistent queue integration

**Files:**
- Modify: `Onda/Article/ArticleConversionService.swift`
- Modify: `Onda/Article/PendingArticlesQueue.swift` (delete `drain()`)
- Modify: `Onda/OndaApp.swift` (drain loop → `resumePersisted()`; pass queue to service)
- Test: `OndaTests/ArticleConversionServiceTests.swift` (extend)
- Test: `OndaTests/PendingArticlesQueueTests.swift` (delete the two drain tests)

**Interfaces:**
- Consumes: `PendingArticlesQueue.Entry/entries()/append/remove/recordAttempt` (Task 1).
- Produces (Task 3 relies on these):
  - `init(modelContext:extract:renderer:persistTranscript:queue:)` — new `queue: PendingArticlesQueue = .standard` parameter (trailing, defaulted: existing call sites compile unchanged).
  - `static let maxAutoAttempts = 3`
  - `func resumePersisted()` — for each queue entry: `attempts < maxAutoAttempts` → `add(url:)` (idempotent vs in-flight); otherwise ensure a failed `Pending` row exists (message `"Conversion failed \(attempts) times — retry to try again."`), without starting work.
  - Queue side-effects: `add` appends; success and `dismiss` remove; each failure records an attempt.

- [ ] **Step 1: Write the failing tests**

Add to `OndaTests/ArticleConversionServiceTests.swift`. The existing `makeService` helper gains a queue: change its signature to

```swift
    private func makeService(ctx: ModelContext,
                             extract: @escaping ArticleConversionService.Extract,
                             renderer: ArticleSpeechRendering = FakeRenderer(),
                             queue: PendingArticlesQueue = PendingArticlesQueue(containerURL: nil))
        -> ArticleConversionService {
        let ts = TranscriptService(modelContext: ctx, engine: nil,
                                   fetch: { _ in Data() }, localURL: { _ in nil })
        return ArticleConversionService(
            modelContext: ctx, extract: extract, renderer: renderer,
            persistTranscript: { ep, cues in ts.persist(cues: cues, for: ep, source: "tts") },
            queue: queue)
    }
```

and add a local temp-queue helper + tests:

```swift
    private func tempQueue() -> PendingArticlesQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("svc-queue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingArticlesQueue(containerURL: dir)
    }

    func test_successfulConversion_removesURLFromPersistentQueue() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        let url = URL(string: "https://example.com/persist-ok")!
        queue.append(url)

        await svc.convert(url)

        XCTAssertTrue(queue.entries().isEmpty, "success must clear the durable entry")
        let ep = try ctx.fetch(FetchDescriptor<Episode>()).first
        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep?.guid ?? "")))
    }

    func test_failedConversion_recordsAttemptAndKeepsEntry() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed },
                              queue: queue)
        let url = URL(string: "https://example.com/persist-fail")!
        svc.add(url: url)   // add() must append to the queue itself
        // Wait for the fire-and-forget task to finish (bounded poll).
        for _ in 0..<100 where svc.pending.first?.failure == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.entries(), [.init(url: url, attempts: 1)])
    }

    func test_dismiss_removesEntryFromQueue() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let svc = makeService(ctx: ctx,
                              extract: { _ in throw ArticleExtractionError.fetchFailed },
                              queue: queue)
        let url = URL(string: "https://example.com/persist-dismiss")!
        svc.add(url: url)
        for _ in 0..<100 where svc.pending.first?.failure == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        svc.dismiss(url: url)
        XCTAssertTrue(queue.entries().isEmpty)
    }

    func test_resumePersisted_convertsSubCapAndFlagsCappedEntries() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let fresh = URL(string: "https://example.com/fresh")!
        let capped = URL(string: "https://example.com/capped")!
        queue.append(fresh)
        queue.append(capped)
        for _ in 0..<ArticleConversionService.maxAutoAttempts { queue.recordAttempt(capped) }

        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        svc.resumePersisted()

        // capped: failed row immediately, no conversion started for it
        XCTAssertEqual(svc.pending.first(where: { $0.id == capped })?.failure,
                       "Conversion failed 3 times — retry to try again.")
        // fresh: converts to an episode; wait bounded for the async add() task
        for _ in 0..<200 {
            if (try? ctx.fetch(FetchDescriptor<Episode>()))?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 1, "only the sub-cap entry converts")
        XCTAssertEqual(queue.entries().map(\.url), [capped], "fresh removed on success; capped kept")
        try? FileManager.default.removeItem(
            at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: eps[0].guid)))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:OndaTests/ArticleConversionServiceTests`
Expected: BUILD FAILURE — no `queue:` init parameter, no `resumePersisted`, no `maxAutoAttempts`.

- [ ] **Step 3: Implement the service changes**

In `Onda/Article/ArticleConversionService.swift`:

1. Add stored property + init parameter (after `persistTranscript` in both):

```swift
    private let queue: PendingArticlesQueue
```

```swift
    init(modelContext: ModelContext, extract: @escaping Extract,
         renderer: ArticleSpeechRendering,
         persistTranscript: @escaping (Episode, [ParsedCue]) -> Void,
         queue: PendingArticlesQueue = .standard) {
        self.modelContext = modelContext
        self.extract = extract
        self.renderer = renderer
        self.persistTranscript = persistTranscript
        self.queue = queue
    }
```

2. Add the cap constant near `articlesFeedURL`:

```swift
    static let maxAutoAttempts = 3
```

3. In `add(url:)`, append to the durable queue as the first side effect after the in-flight guard:

```swift
    func add(url: URL) {
        // Idempotent while in flight; re-adding a failed URL restarts it.
        if inFlight[url] != nil { return }
        queue.append(url)
        ...unchanged...
    }
```

4. In `dismiss(url:)`, first line: `queue.remove(url)`.

5. In `convert(_:generation:)`'s success path, next to `pending.removeAll { $0.id == url }` after `insertEpisode(...)`: add `queue.remove(url)`.

6. In the `catch` block, before `setFailure(...)` (after the `Task.isCancelled` guard):

```swift
            if isCurrentGeneration(url, id) { queue.recordAttempt(url) }
```

7. Add `resumePersisted()` (public section, after `dismiss`):

```swift
    /// Foreground reconciliation: restart every durable entry under the auto-retry cap
    /// (idempotent — add() ignores URLs already in flight) and surface capped entries as
    /// failed rows that only a manual RETRY will run again. Replaces the old drain-once
    /// handoff: entries persist until success or explicit dismiss.
    func resumePersisted() {
        for entry in queue.entries() {
            if entry.attempts < Self.maxAutoAttempts {
                add(url: entry.url)
            } else if inFlight[entry.url] == nil,
                      !pending.contains(where: { $0.id == entry.url }) {
                pending.append(Pending(
                    id: entry.url,
                    failure: "Conversion failed \(entry.attempts) times — retry to try again."))
            }
        }
    }
```

8. Update the class doc comment's first lines to reflect persistence:

```swift
/// Orchestrates URL → extracted article → sentences → rendered TTS audio → SwiftData rows.
/// Not-yet-converted URLs persist in the shared PendingArticlesQueue (App Group JSON) so
/// conversions survive app termination; visible progress state (`pending`) remains
/// ephemeral. Rows are only inserted after the full pipeline succeeds, so a half-finished
/// conversion never shows up as a broken episode.
```

- [ ] **Step 4: Rewire OndaApp and delete drain()**

In `Onda/OndaApp.swift`, replace the drain loop in the `.active` branch:

```swift
                    if phase == .active {
                        articles.resumePersisted()
                        Task { [refresh] in await refresh.refreshAll() }
                    } else if phase == .background {
```

In `Onda/Article/PendingArticlesQueue.swift`, delete `drain()` (its doc comment says this task removes it). In `OndaTests/PendingArticlesQueueTests.swift`, delete `test_appendThenDrain_returnsURLsInOrderAndClears` and `test_corruptFile_drainsEmpty`, and add a corrupt-file replacement:

```swift
    func test_corruptFile_entriesEmpty() {
        let q = tempQueue()
        q.append(URL(string: "https://ex.com/a")!)
        let file = q.containerURL!.appendingPathComponent("pending-articles.json")
        try! Data("not json".utf8).write(to: file)
        XCTAssertEqual(q.entries(), [])
    }
```

- [ ] **Step 5: Run both test classes + build**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests/ArticleConversionServiceTests -only-testing:OndaTests/PendingArticlesQueueTests && swiftlint lint --quiet`
Expected: all pass (12 service + 9 queue), lint clean.

- [ ] **Step 6: Commit**

```bash
git add Onda/Article/ Onda/OndaApp.swift OndaTests/
git commit -m "feat: persistent conversion queue — survive termination, attempt-capped auto-retry"
```

---

### Task 3: Background execution — continuation + BGProcessingTask

**Files:**
- Modify: `Onda/Article/ArticleConversionService.swift`
- Modify: `Onda/OndaApp.swift` (register + schedule)
- Modify: `project.yml` (permitted identifier)
- Test: `OndaTests/ArticleConversionServiceTests.swift` (extend — `processQueueForBackground` logic only; BGTaskScheduler registration is not unit-testable)

**Interfaces:**
- Consumes: Task 2's queue integration; `FeedRefreshService.registerBackgroundTask()` as the registration pattern (`Onda/Services/FeedRefreshService.swift:50-64`).
- Produces:
  - `static let backgroundTaskId = "com.onda.articles.convert"`
  - `func registerBackgroundTask()`, `func scheduleBackgroundProcessing()`
  - `func processQueueForBackground() async` — sequential, skips in-flight URLs, stops on cancellation.
  - Failure logging via `os.Logger` (subsystem `"com.chasegilliam.Onda"`, category `"articles"`).

- [ ] **Step 1: Write the failing tests**

Add to `OndaTests/ArticleConversionServiceTests.swift`:

```swift
    func test_processQueueForBackground_convertsSubCapEntriesSequentially() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let a = URL(string: "https://example.com/bg-a")!
        let b = URL(string: "https://example.com/bg-b")!
        let capped = URL(string: "https://example.com/bg-capped")!
        queue.append(a)
        queue.append(b)
        queue.append(capped)
        for _ in 0..<ArticleConversionService.maxAutoAttempts { queue.recordAttempt(capped) }

        let svc = makeService(ctx: ctx, extract: { _ in self.article }, queue: queue)
        await svc.processQueueForBackground()

        let eps = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(eps.count, 2, "both sub-cap entries convert; capped one is skipped")
        XCTAssertEqual(queue.entries().map(\.url), [capped])
        for ep in eps {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }

    func test_processQueueForBackground_skipsInFlightURL() async throws {
        let ctx = try makeContext()
        let queue = tempQueue()
        let url = URL(string: "https://example.com/bg-inflight")!
        queue.append(url)
        let gate = GatedRenderer()   // reuse the existing gated fake from the race tests
        let svc = makeService(ctx: ctx, extract: { _ in self.article }, renderer: gate, queue: queue)
        svc.add(url: url)
        // Wait until the gated conversion is genuinely inside render()
        for _ in 0..<100 where gate.enterCount == 0 { try await Task.sleep(for: .milliseconds(20)) }

        await svc.processQueueForBackground()   // must NOT start a second attempt

        XCTAssertEqual(gate.enterCount, 1, "background pass must skip the in-flight URL")
        gate.release()
        for _ in 0..<200 {
            if svc.pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)
        if let ep = try ctx.fetch(FetchDescriptor<Episode>()).first {
            try? FileManager.default.removeItem(
                at: DownloadManager.fileURL(named: ArticleConversionService.audioFileName(for: ep.guid)))
        }
    }
```

(Adapt the `GatedRenderer` name/API to whatever the existing race tests defined — reuse, don't duplicate. If its counter isn't named `enterCount`, use the existing name.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:OndaTests/ArticleConversionServiceTests`
Expected: BUILD FAILURE — `processQueueForBackground` not found.

- [ ] **Step 3: Implement**

In `Onda/Article/ArticleConversionService.swift`:

1. Imports (top of file):

```swift
import BackgroundTasks
import OSLog
#if canImport(UIKit)
import UIKit
#endif
```

2. Constants + logger (near `articlesFeedURL`):

```swift
    static let backgroundTaskId = "com.onda.articles.convert"
    private static let log = Logger(subsystem: "com.chasegilliam.Onda", category: "articles")
```

3. Background continuation: in `add(url:)`, wrap the conversion Task's body:

```swift
        let task: Task<Void, Never> = Task { [weak self] in
            let bg = Self.beginBackgroundContinuation()
            defer { Self.endBackgroundContinuation(bg) }
            await self?.convert(url, generation: id)
        }
```

and add the helpers (private section):

```swift
    /// ~30s of continued execution when the user backgrounds the app mid-conversion —
    /// enough for typical articles. If it expires, the conversion freezes with the app;
    /// its queue entry survives for the BGProcessingTask window.
    #if canImport(UIKit)
    private static func beginBackgroundContinuation() -> UIBackgroundTaskIdentifier {
        let holder = ContinuationHolder()
        let id = UIApplication.shared.beginBackgroundTask(withName: "article-conversion") {
            holder.end()
        }
        holder.id = id
        return id
    }

    private static func endBackgroundContinuation(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    /// beginBackgroundTask's expiration handler needs the identifier the call returns —
    /// this box breaks the chicken-and-egg without capturing a mutated local.
    private final class ContinuationHolder: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #else
    private static func beginBackgroundContinuation() -> Int { 0 }
    private static func endBackgroundContinuation(_ id: Int) {}
    #endif
```

(If `UIApplication.shared` triggers a MainActor-isolation diagnostic in the expiration handler, hop with `Task { @MainActor in ... }` inside `end()` — note it in the report.)

4. BGProcessingTask registration/scheduling/processing (public section), mirroring `FeedRefreshService.registerBackgroundTask`'s exact structure:

```swift
    /// Must be called before the app finishes launching (OndaApp.init), same as
    /// FeedRefreshService. The handler runs with the app in the background: process
    /// durable entries one at a time so an expiration cancels at most one conversion.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskId,
                                        using: nil) { task in
            let op = Task { @MainActor [weak self] in
                await self?.processQueueForBackground()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { op.cancel() }
        }
    }

    func scheduleBackgroundProcessing() {
        guard queue.entries().contains(where: { $0.attempts < Self.maxAutoAttempts })
        else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true   // extraction fetches the page
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Sequential on purpose: TTS rendering is CPU-bound, and one-at-a-time means an
    /// expiration cancels a single conversion whose entry stays queued. Skips URLs with
    /// an in-flight attempt — a foreground conversion suspended mid-render resumes
    /// concurrently with a background wake, and double-converting duplicates episodes.
    func processQueueForBackground() async {
        for entry in queue.entries() where entry.attempts < Self.maxAutoAttempts {
            guard !Task.isCancelled else { return }
            guard inFlight[entry.url] == nil else { continue }
            await convert(entry.url)
        }
    }
```

5. Failure logging: in `convert(_:generation:)`'s catch block, alongside the attempt recording:

```swift
            if isCurrentGeneration(url, id) { queue.recordAttempt(url) }
            Self.log.error("conversion failed for \(url.absoluteString, privacy: .public): \(error)")
```

6. `project.yml`: extend the permitted identifiers line:

```yaml
        BGTaskSchedulerPermittedIdentifiers: [com.onda.refresh, com.onda.articles.convert]
```

7. `Onda/OndaApp.swift`: after the `_articles = State(...)` construction, register (store the service in a local first if needed):

```swift
            let articlesService = OndaApp.makeArticleService(context: c.mainContext, ts: ts)
            articlesService.registerBackgroundTask()
            _articles = State(initialValue: articlesService)
```

(adapt to the actual current shape — `makeArticleService` already exists) and in the `.background` branch:

```swift
                    } else if phase == .background {
                        articles.scheduleBackgroundProcessing()
                        refresh.scheduleBackgroundRefresh()
                    }
```

- [ ] **Step 4: Run tests, full build, lint**

Run: `xcodegen generate && xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OndaTests && swiftlint lint --quiet`
Expected: full unit suite passes; lint clean.

- [ ] **Step 5: Commit**

```bash
git add Onda/Article/ArticleConversionService.swift Onda/OndaApp.swift project.yml Onda.xcodeproj/project.pbxproj OndaTests/
git commit -m "feat: background conversion — task continuation + BGProcessingTask queue drain"
```

---

### Task 4: End-to-end verification (manual, simulator)

**Files:** none (verification only; use `.claude/skills/verify/SKILL.md` for the build/drive recipe)

- [ ] **Step 1: Foreground-leave continuation**

Dedicated simulator, local article server. Add an article; the moment the pending row shows "Synthesizing…", press Home (Device > Home). Wait 30s, reopen Onda. Expected: the episode exists (conversion finished in the background continuation window).

- [ ] **Step 2: Termination + relaunch reconciliation**

Add an article and immediately terminate the app (`xcrun simctl terminate <UDID> com.chasegilliam.Onda`). Relaunch. Expected: conversion restarts automatically (pending row reappears) and completes; exactly ONE episode for that URL (no duplicate from the lost first attempt).

- [ ] **Step 3: Attempt cap**

With the article server STOPPED, add its URL; let it fail; relaunch the app twice more (each relaunch auto-retries and fails). After the third failure, relaunch once more. Expected: no auto-retry — a failed row reading "Conversion failed 3 times — retry to try again." Start the server, tap RETRY. Expected: converts successfully and the row clears.

- [ ] **Step 4: BGProcessingTask (best-effort)**

`BGTaskScheduler` tasks can't be triggered on demand outside Xcode's debugger (`_simulateLaunchForTaskWithIdentifier:`). Verify what's verifiable: registration doesn't crash at launch, scheduling submits without error while queued entries exist (check `log stream --predicate 'subsystem == "com.apple.BGTaskScheduler"'` for the submission), and document that the handler path is covered by unit tests (`processQueueForBackground`) rather than a live BG wake.

- [ ] **Step 5: Record results**

Report per the verify skill format; fix-and-re-verify anything that fails before closing out.
