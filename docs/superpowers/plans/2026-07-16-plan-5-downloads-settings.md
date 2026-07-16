# Onda Plan 5: Downloads, Settings & Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download episodes for offline playback (with progress + retry), auto-download new episodes for opted-in shows, provide the per-show settings sheet (all controls from the prototype), a Downloads & Storage manager, and background feed refresh.

**Architecture:** `DownloadManager` (`@Observable`) drives a background `URLSession`; its delegate writes `DownloadedFile` rows through a dedicated `@ModelActor` (`PersistenceActor`) so background completions never touch a view context off-thread. `FeedRefreshService` refreshes subscriptions on foreground + a `BGAppRefreshTask` and triggers auto-downloads. The per-show settings sheet and Downloads screen are SwiftUI views bound to `ShowSettings` / `DownloadedFile`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`@ModelActor`), URLSession background config, BackgroundTasks, XCTest.

## Global Constraints

- Deployment target iOS 17.0 (Plan 1 Global Constraints apply verbatim).
- Background downloads use a **background** `URLSessionConfiguration`; SwiftData writes for completions go through a `@ModelActor`, never a view `ModelContext`.
- Downloaded files live in Application Support under `Downloads/`; `DownloadedFile.localFileName` stores the filename only (Plan 3's `PlaybackManager.localURL(for:)` resolves it).
- Failed downloads auto-retry **once**, then surface a manual retry.
- All settings controls persist to `ShowSettings` and take effect immediately (playback reads them live via Plans 3–4).
- Visual language + services from Plans 1–4.

**Depends on:** Plans 1–4 complete.

---

## File Structure

```
Onda/
  Downloads/
    PersistenceActor.swift    — @ModelActor for off-main writes
    DownloadManager.swift     — @Observable; background URLSession + progress + retry
    DownloadState.swift       — per-episode state enum (pure)
  Services/
    FeedRefreshService.swift  — foreground + BGAppRefreshTask refresh + auto-download
  Settings/
    ShowSettingsSheet.swift   — per-podcast settings (speed/boost/silence/adskip/autodl/trim/notif)
    SegmentedRow.swift        — reusable segmented control row (brutal style)
  Profile/
    DownloadsStorageView.swift — downloaded episodes list + storage used + delete
  Shell/
    ProfileView.swift         — MODIFY: link to Downloads & Storage
    LibraryView.swift / EpisodeListView — MODIFY: settings gear + download button → DownloadManager
OndaTests/
  DownloadStateTests.swift
  DownloadManagerTests.swift
  FeedRefreshServiceTests.swift
```

---

### Task 1: DownloadState (pure) + PersistenceActor

**Files:**
- Create: `Onda/Downloads/DownloadState.swift`, `Onda/Downloads/PersistenceActor.swift`
- Create: `OndaTests/DownloadStateTests.swift`

**Interfaces:**
- Produces:
  - `enum DownloadState: Equatable { case none, downloading(progress: Double), downloaded, failed }`
  - `@ModelActor actor PersistenceActor` with `func recordDownload(episodeGuid: String, fileName: String, sizeBytes: Int64) throws` and `func deleteDownload(episodeGuid: String) throws` (looks up `Episode` by guid, attaches/removes `DownloadedFile`).

- [ ] **Step 1: Write the failing state test**

Create `OndaTests/DownloadStateTests.swift`:

```swift
//  DownloadStateTests.swift
import XCTest
@testable import Onda

final class DownloadStateTests: XCTestCase {
    func test_progressEquality() {
        XCTAssertEqual(DownloadState.downloading(progress: 0.5), .downloading(progress: 0.5))
        XCTAssertNotEqual(DownloadState.downloading(progress: 0.5), .downloading(progress: 0.6))
        XCTAssertNotEqual(DownloadState.none, .downloaded)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/DownloadStateTests`
Expected: FAIL — `cannot find 'DownloadState' in scope`.

- [ ] **Step 3: Write DownloadState + PersistenceActor**

Create `Onda/Downloads/DownloadState.swift`:

```swift
//  DownloadState.swift
import Foundation

enum DownloadState: Equatable {
    case none
    case downloading(progress: Double)
    case downloaded
    case failed
}
```

Create `Onda/Downloads/PersistenceActor.swift`:

```swift
//  PersistenceActor.swift
import Foundation
import SwiftData

@ModelActor
actor PersistenceActor {
    func recordDownload(episodeGuid: String, fileName: String, sizeBytes: Int64) throws {
        let d = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == episodeGuid })
        guard let ep = try modelContext.fetch(d).first else { return }
        let file = DownloadedFile(localFileName: fileName, fileSizeBytes: sizeBytes, downloadedAt: .now)
        file.episode = ep
        ep.downloadedFile = file
        modelContext.insert(file)
        try modelContext.save()
    }

    func deleteDownload(episodeGuid: String) throws {
        let d = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == episodeGuid })
        guard let ep = try modelContext.fetch(d).first, let file = ep.downloadedFile else { return }
        modelContext.delete(file)
        ep.downloadedFile = nil
        try modelContext.save()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/DownloadStateTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Onda/Downloads/DownloadState.swift Onda/Downloads/PersistenceActor.swift OndaTests/DownloadStateTests.swift
git commit -m "feat: DownloadState enum + PersistenceActor (@ModelActor) for off-main writes"
```

---

### Task 2: DownloadManager

**Files:**
- Create: `Onda/Downloads/DownloadManager.swift`
- Create: `OndaTests/DownloadManagerTests.swift`

**Interfaces:**
- Consumes: `PersistenceActor`, `Episode`.
- Produces:
  - `@Observable final class DownloadManager: NSObject`
  - `init(persistence: PersistenceActor, session: URLSessionProtocol? = nil)` (session injectable for tests)
  - `func state(for episode: Episode) -> DownloadState` (reads a `[guid: DownloadState]` map)
  - `func download(_ episode: Episode)` — starts a background download task keyed by guid; on finish moves the file into `Downloads/`, calls `persistence.recordDownload`, sets state `.downloaded`
  - `func delete(_ episode: Episode)` — removes file + calls `persistence.deleteDownload`, state `.none`
  - Retry: a failed task auto-retries once; second failure → `.failed`
  - `func handleFinished(guid:tempURL:totalBytes:)` and `func handleFailed(guid:)` — the delegate-facing seams, tested directly without a real network.

- [ ] **Step 1: Write failing tests (state transitions + retry, via delegate seams)**

Create `OndaTests/DownloadManagerTests.swift`:

```swift
//  DownloadManagerTests.swift
import XCTest
import SwiftData
@testable import Onda

final class DownloadManagerTests: XCTestCase {
    private func makeEnv() throws -> (ModelContext, PersistenceActor, Episode) {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let ep = Episode(guid: "g1", title: "E", publishDate: .now, duration: 100,
                         audioURL: URL(string: "https://ex.com/e.mp3")!, notes: "")
        ep.podcast = pod; pod.episodes.append(ep)
        ctx.insert(pod); ctx.insert(ep); try ctx.save()
        let actor = PersistenceActor(modelContainer: container)
        return (ctx, actor, ep)
    }

    func test_download_setsDownloadingState() throws {
        let (_, actor, ep) = try makeEnv()
        let dm = DownloadManager(persistence: actor, session: FakeURLSession())
        dm.download(ep)
        if case .downloading = dm.state(for: ep) {} else { XCTFail("expected downloading") }
    }

    func test_finished_writesFileAndMarksDownloaded() async throws {
        let (ctx, actor, ep) = try makeEnv()
        let dm = DownloadManager(persistence: actor, session: FakeURLSession())
        dm.download(ep)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t.mp3")
        try Data([0,1,2,3]).write(to: tmp)
        await dm.handleFinished(guid: "g1", tempURL: tmp, totalBytes: 4)
        XCTAssertEqual(dm.state(for: ep), .downloaded)
        // Persistence wrote a DownloadedFile
        try await Task.sleep(for: .milliseconds(50))
        let refreshed = try ctx.fetch(FetchDescriptor<Episode>()).first
        XCTAssertNotNil(refreshed?.downloadedFile)
    }

    func test_failure_retriesOnce_thenFails() throws {
        let (_, actor, ep) = try makeEnv()
        let dm = DownloadManager(persistence: actor, session: FakeURLSession())
        dm.download(ep)
        dm.handleFailed(guid: "g1")     // first failure → retry
        if case .downloading = dm.state(for: ep) {} else { XCTFail("expected retry (downloading)") }
        dm.handleFailed(guid: "g1")     // second failure → failed
        XCTAssertEqual(dm.state(for: ep), .failed)
    }
}

// Minimal fakes
final class FakeURLSession: URLSessionProtocol {
    func downloadTask(with url: URL) -> URLSessionDownloadTask {
        // A resumeless dummy; DownloadManager tests drive completion via handleFinished/handleFailed.
        URLSession(configuration: .default).downloadTask(with: url)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/DownloadManagerTests`
Expected: FAIL — `cannot find 'DownloadManager' in scope`.

- [ ] **Step 3: Write DownloadManager**

Create `Onda/Downloads/DownloadManager.swift`:

```swift
//  DownloadManager.swift
import Foundation
import SwiftData

protocol URLSessionProtocol { func downloadTask(with url: URL) -> URLSessionDownloadTask }
extension URLSession: URLSessionProtocol {}

@Observable
final class DownloadManager: NSObject {
    private let persistence: PersistenceActor
    private var session: URLSessionProtocol!
    private var states: [String: DownloadState] = [:]     // keyed by episode guid
    private var retries: [String: Int] = [:]
    private var urlByGuid: [String: URL] = [:]
    private var guidByTaskURL: [URL: String] = [:]

    static let downloadsSubdir = "Downloads"

    init(persistence: PersistenceActor, session: URLSessionProtocol? = nil) {
        self.persistence = persistence
        super.init()
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.background(withIdentifier: "com.onda.downloads")
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }
    }

    func state(for episode: Episode) -> DownloadState {
        if episode.downloadedFile != nil { return .downloaded }
        return states[episode.guid] ?? .none
    }

    func download(_ episode: Episode) {
        let guid = episode.guid
        states[guid] = .downloading(progress: 0)
        urlByGuid[guid] = episode.audioURL
        guidByTaskURL[episode.audioURL] = guid
        let task = session.downloadTask(with: episode.audioURL)
        task.resume()
    }

    func delete(_ episode: Episode) {
        let url = Self.fileURL(named: fileName(for: episode.guid))
        try? FileManager.default.removeItem(at: url)
        states[episode.guid] = DownloadState.none
        Task { try? await persistence.deleteDownload(episodeGuid: episode.guid) }
    }

    // MARK: delegate seams (unit-tested directly)

    func handleFinished(guid: String, tempURL: URL, totalBytes: Int64) async {
        let dest = Self.fileURL(named: fileName(for: guid))
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: tempURL, to: dest)
        states[guid] = .downloaded
        retries[guid] = nil
        try? await persistence.recordDownload(episodeGuid: guid,
                                              fileName: fileName(for: guid), sizeBytes: totalBytes)
    }

    func handleFailed(guid: String) {
        let attempts = (retries[guid] ?? 0) + 1
        retries[guid] = attempts
        if attempts <= 1, let url = urlByGuid[guid] {
            states[guid] = .downloading(progress: 0)   // auto-retry once
            let task = session.downloadTask(with: url); task.resume()
        } else {
            states[guid] = .failed
        }
    }

    func retryManually(guid: String) {
        retries[guid] = 0
        if let url = urlByGuid[guid] {
            states[guid] = .downloading(progress: 0)
            session.downloadTask(with: url).resume()
        }
    }

    private func fileName(for guid: String) -> String {
        let safe = guid.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        return "\(safe).mp3"
    }

    static func fileURL(named name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(downloadsSubdir)
        return dir.appendingPathComponent(name)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let src = downloadTask.originalRequest?.url, let guid = guidByTaskURL[src] else { return }
        let total = downloadTask.countOfBytesReceived
        // Move synchronously here (temp file valid only during callback), then persist async.
        let dest = Self.fileURL(named: fileName(for: guid))
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        Task { await handleFinished(guid: guid, tempURL: dest, totalBytes: total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let src = downloadTask.originalRequest?.url, let guid = guidByTaskURL[src],
              totalBytesExpectedToWrite > 0 else { return }
        states[guid] = .downloading(progress: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let src = task.originalRequest?.url, let guid = guidByTaskURL[src] else { return }
        if error != nil { handleFailed(guid: guid) }
    }
}
```

> Note: `handleFinished` in tests receives an already-moved temp file; the delegate path moves the file itself then calls it (the second move is a no-op because the dest already exists — guarded by `removeItem`). This keeps one persistence path for both real and test flows.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/DownloadManagerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Downloads/DownloadManager.swift OndaTests/DownloadManagerTests.swift
git commit -m "feat: DownloadManager (background URLSession, progress, retry-once, @ModelActor persistence)"
```

---

### Task 3: Segmented row + per-show settings sheet

**Files:**
- Create: `Onda/Settings/SegmentedRow.swift`, `Onda/Settings/ShowSettingsSheet.swift`
- Modify: `Onda/Library/EpisodeListView.swift`, `Onda/Player/NowPlayingView.swift` (open the sheet)

**Interfaces:**
- Consumes: `ShowSettings` (bound), `PlaybackManager.applyAudioSettings()`.
- Produces:
  - `SegmentedRow(title:options:selection:onChange:)` — brutal-styled segmented picker.
  - `ShowSettingsSheet(podcast:)` — Playback (Speed cycle, Voice Boost segmented, Skip Silence toggle), Ads & Downloads (Ad Skip segmented, Auto-Download toggle), Trim Episode (Skip Intro/Outro ±5s steppers), Notifications segmented. Mutations persist to `ShowSettings` and call `applyAudioSettings()`.

- [ ] **Step 1: Write the segmented row**

Create `Onda/Settings/SegmentedRow.swift`:

```swift
//  SegmentedRow.swift
import SwiftUI

struct SegmentedRow<T: Hashable>: View {
    @Environment(AppTheme.self) private var theme
    let options: [(label: String, value: T)]
    let selection: T
    var onChange: (T) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { opt in
                Button { onChange(opt.value) } label: {
                    Text(opt.label).font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(opt.value == selection ? .white : theme.color(.textSecondary))
                        .background(opt.value == selection ? theme.color(.accent) : theme.color(.bg))
                        .brutalBorder(width: 2)
                }.buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 2: Write the settings sheet**

Create `Onda/Settings/ShowSettingsSheet.swift`:

```swift
//  ShowSettingsSheet.swift
import SwiftUI

struct ShowSettingsSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Bindable var podcast: Podcast

    private var s: ShowSettings {
        if podcast.settings == nil {
            let ns = ShowSettings.makeDefault(); ns.podcast = podcast; podcast.settings = ns
        }
        return podcast.settings!
    }
    private let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Playback") {
                        row("Speed") {
                            Button("\(s.speed, specifier: "%g")×") { cycleSpeed() }
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.color(.text))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice Boost").font(.system(size: 16)).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Off", 0), ("Med", 1), ("High", 2)],
                                         selection: s.voiceBoost) { s.voiceBoost = $0; playback.applyAudioSettings() }
                        }
                        Toggle("Skip Silence", isOn: Binding(
                            get: { s.skipSilence }, set: { s.skipSilence = $0; playback.applyAudioSettings() }))
                            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
                    }
                    section("Ads & Downloads") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ad Skip").font(.system(size: 16)).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Off", "off"), ("Manual", "manual"), ("Auto", "auto")],
                                         selection: s.adSkipMode) { s.adSkipMode = $0 }
                        }
                        Toggle("Auto-Download New Episodes", isOn: Binding(
                            get: { s.autoDownload }, set: { s.autoDownload = $0 }))
                            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
                    }
                    section("Trim Episode") {
                        stepperRow("Skip Intro", value: Binding(get: { s.introTrimSec }, set: { s.introTrimSec = $0 }))
                        stepperRow("Skip Outro", value: Binding(get: { s.outroTrimSec }, set: { s.outroTrimSec = $0 }))
                    }
                    section("Notifications") {
                        SegmentedRow(options: [("All", "all"), ("Important", "important"), ("None", "none")],
                                     selection: s.notifMode) { s.notifMode = $0 }
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle(podcast.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func cycleSpeed() {
        let i = speedSteps.firstIndex(of: s.speed) ?? 1
        s.speed = speedSteps[(i + 1) % speedSteps.count]
        playback.applyAudioSettings()
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            content()
        }
    }
    @ViewBuilder private func row(_ title: String, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack { Text(title).font(.system(size: 16)).foregroundStyle(theme.color(.text)); Spacer(); trailing() }
    }
    private func stepperRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(theme.color(.text)); Spacer()
            Button("−") { value.wrappedValue = max(0, value.wrappedValue - 5) }
            Text("\(value.wrappedValue)s").monospacedDigit().frame(minWidth: 44)
                .foregroundStyle(theme.color(.text))
            Button("+") { value.wrappedValue = min(60, value.wrappedValue + 5) }
        }
        .foregroundStyle(theme.color(.accent)).font(.system(size: 18, weight: .semibold))
    }
}
```

- [ ] **Step 3: Open the sheet from Episode List (gear) and Now Playing (overflow)**

In `Onda/Library/EpisodeListView.swift`, add `@State private var showSettings = false`, a gear button in the header (`Button { showSettings = true } label: { Image(systemName: "gearshape") }`), and `.sheet(isPresented: $showSettings) { ShowSettingsSheet(podcast: podcast) }`.

In `Onda/Player/NowPlayingView.swift` header, add a settings button and `@State private var showSettings = false`, presenting `ShowSettingsSheet(podcast: ep.podcast!)` when `ep?.podcast != nil`.

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Onda/Settings Onda/Library/EpisodeListView.swift Onda/Player/NowPlayingView.swift
git commit -m "feat: per-show settings sheet (all prototype controls) + entry points"
```

---

### Task 4: Wire download buttons + Downloads & Storage screen

**Files:**
- Create: `Onda/Profile/DownloadsStorageView.swift`
- Modify: `Onda/Library/EpisodeListView.swift`, `Onda/Shell/ProfileView.swift`, `Onda/OndaApp.swift`

**Interfaces:**
- Consumes: `DownloadManager` (environment), `DownloadState`, `@Query` of downloaded episodes.
- Produces:
  - `EpisodeRow.onDownload` → `downloads.download(ep)`; row shows progress/checkmark/failed-retry from `downloads.state(for:)`.
  - `DownloadsStorageView` — list of episodes with a `downloadedFile`, total storage used, swipe-to-delete → `downloads.delete(ep)`.
  - App injects `DownloadManager(persistence: PersistenceActor(modelContainer:))`.

- [ ] **Step 1: Write the Downloads & Storage screen**

Create `Onda/Profile/DownloadsStorageView.swift`:

```swift
//  DownloadsStorageView.swift
import SwiftUI
import SwiftData

struct DownloadsStorageView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Query private var episodes: [Episode]

    private var downloaded: [Episode] { episodes.filter { $0.downloadedFile != nil } }
    private var totalBytes: Int64 { downloaded.reduce(0) { $0 + ($1.downloadedFile?.fileSizeBytes ?? 0) } }
    private var totalStr: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage used").foregroundStyle(theme.color(.text))
                    Spacer()
                    Text(totalStr).foregroundStyle(theme.color(.textTertiary)).monospacedDigit()
                }
            }
            Section("Downloaded") {
                if downloaded.isEmpty {
                    Text("No downloads").foregroundStyle(theme.color(.textTertiary))
                } else {
                    ForEach(downloaded, id: \.guid) { ep in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).font(.system(size: 15, weight: .semibold))
                            Text(ep.podcast?.title ?? "").font(.system(size: 12.5))
                                .foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                    .onDelete { idx in idx.map { downloaded[$0] }.forEach(downloads.delete) }
                }
            }
        }
        .navigationTitle("Downloads & Storage")
    }
}
```

- [ ] **Step 2: Wire the Episode List download button to DownloadManager**

In `Onda/Library/EpisodeListView.swift`, add `@Environment(DownloadManager.self) private var downloads` and change the row to pass an `onDownload` that starts/deletes based on current state:

```swift
                    EpisodeRow(episode: ep,
                               onPlay: { playback.play(ep) },
                               onDownload: {
                                   switch downloads.state(for: ep) {
                                   case .downloaded: downloads.delete(ep)
                                   case .failed:     downloads.retryManually(guid: ep.guid)
                                   default:          downloads.download(ep)
                                   }
                               })
```

(The row's existing icon already reflects `episode.downloadedFile == nil`; downloaded state now updates it after completion.)

- [ ] **Step 3: Link Profile → Downloads & Storage; inject DownloadManager**

In `Onda/Shell/ProfileView.swift`, wrap the body in a `NavigationStack` and make the existing "Downloads & Storage" row a `NavigationLink(destination: DownloadsStorageView())`.

In `Onda/OndaApp.swift`, add:
```swift
    @State private var downloads: DownloadManager
```
in `init` after the container:
```swift
            let persistence = PersistenceActor(modelContainer: c)
            _downloads = State(initialValue: DownloadManager(persistence: persistence))
```
and add `.environment(downloads)` in `body`.

- [ ] **Step 4: Build and run — verify download + storage + delete**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Launch: subscribe to a show, tap an episode's download button → progresses to a checkmark; Profile → Downloads & Storage lists it with a size; swipe to delete removes it; the episode then streams instead of playing locally.

- [ ] **Step 5: Commit**

```bash
git add Onda/Profile/DownloadsStorageView.swift Onda/Library/EpisodeListView.swift Onda/Shell/ProfileView.swift Onda/OndaApp.swift
git commit -m "feat: download buttons wired + Downloads & Storage screen"
```

---

### Task 5: FeedRefreshService + auto-download + background task

**Files:**
- Create: `Onda/Services/FeedRefreshService.swift`
- Create: `OndaTests/FeedRefreshServiceTests.swift`
- Modify: `Onda/OndaApp.swift` (register + trigger)

**Interfaces:**
- Consumes: `SubscriptionService.refreshEpisodes`, `DownloadManager.download`, `@Query`/fetch of subscribed podcasts.
- Produces:
  - `@Observable final class FeedRefreshService`
  - `init(modelContext: ModelContext, subscriptions: SubscriptionService, downloads: DownloadManager)`
  - `func refreshAll() async` — for each subscribed podcast: `refreshEpisodes`, then for any newly-added episode where `settings.autoDownload`, call `downloads.download(_:)`
  - `func newEpisodesAfterRefresh(for:knownGuids:) -> [Episode]` (pure helper, tested) — given the pre-refresh guid set, returns episodes now present that weren't before.
  - Registers a `BGAppRefreshTask` (id `com.onda.refresh`) that calls `refreshAll()`; triggered on `.active` scene phase too.

- [ ] **Step 1: Write the failing pure-helper + auto-download test**

Create `OndaTests/FeedRefreshServiceTests.swift`:

```swift
//  FeedRefreshServiceTests.swift
import XCTest
import SwiftData
@testable import Onda

private struct StubFeeds: FeedFetching {
    var feed: ParsedFeed
    func fetchFeed(_ url: URL) async throws -> ParsedFeed { feed }
}

final class FeedRefreshServiceTests: XCTestCase {
    private func env(feedGuids: [String]) throws -> (ModelContext, SubscriptionService, DownloadManager, PersistenceActor) {
        let container = try ModelContainer(for: Schema(ondaSchema),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let feed = ParsedFeed(title: "S", author: "A", artworkURL: nil, category: "Tech",
                              episodes: feedGuids.map {
                                  ParsedEpisode(guid: $0, title: $0, publishDate: .now, duration: 100,
                                                audioURL: URL(string: "https://ex.com/\($0).mp3")!,
                                                notes: "", chaptersURL: nil) })
        let subs = SubscriptionService(modelContext: ctx, feeds: StubFeeds(feed: feed))
        let actor = PersistenceActor(modelContainer: container)
        let dm = DownloadManager(persistence: actor, session: FakeURLSession())
        return (ctx, subs, dm, actor)
    }

    func test_newEpisodesAfterRefresh_returnsOnlyNewGuids() throws {
        let (ctx, subs, dm, _) = try env(feedGuids: ["a", "b"])
        let svc = FeedRefreshService(modelContext: ctx, subscriptions: subs, downloads: dm)
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!, title: "S", author: "A",
                          artworkURL: nil, category: "Tech", itunesId: 1)
        let a = Episode(guid: "a", title: "a", publishDate: .now, duration: 100,
                        audioURL: URL(string: "https://ex.com/a.mp3")!, notes: "")
        a.podcast = pod; pod.episodes.append(a)
        let b = Episode(guid: "b", title: "b", publishDate: .now, duration: 100,
                        audioURL: URL(string: "https://ex.com/b.mp3")!, notes: "")
        b.podcast = pod; pod.episodes.append(b)
        let newOnes = svc.newEpisodesAfterRefresh(for: pod, knownGuids: ["a"])
        XCTAssertEqual(newOnes.map(\.guid), ["b"])
    }

    func test_refreshAll_autoDownloadsNewEpisodesForOptedInShows() async throws {
        let (ctx, subs, dm, _) = try env(feedGuids: ["a", "b"])
        let dto = PodcastDTO(collectionId: 1, collectionName: "S", artistName: "A",
                             feedUrl: URL(string: "https://ex.com/f.xml"),
                             artworkUrl600: nil, primaryGenreName: "Tech")
        let pod = try await subs.subscribe(to: dto)     // starts with a,b
        pod.settings?.autoDownload = true
        try ctx.save()
        let svc = FeedRefreshService(modelContext: ctx, subscriptions: subs, downloads: dm)
        await svc.refreshAll()   // no new episodes → nothing downloads
        XCTAssertEqual(dm.state(for: pod.episodes.first!), .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/FeedRefreshServiceTests`
Expected: FAIL — `cannot find 'FeedRefreshService' in scope`.

- [ ] **Step 3: Write FeedRefreshService**

Create `Onda/Services/FeedRefreshService.swift`:

```swift
//  FeedRefreshService.swift
import Foundation
import SwiftData
import BackgroundTasks

@Observable
final class FeedRefreshService {
    static let taskId = "com.onda.refresh"
    private let modelContext: ModelContext
    private let subscriptions: SubscriptionService
    private let downloads: DownloadManager

    init(modelContext: ModelContext, subscriptions: SubscriptionService, downloads: DownloadManager) {
        self.modelContext = modelContext
        self.subscriptions = subscriptions
        self.downloads = downloads
    }

    func newEpisodesAfterRefresh(for podcast: Podcast, knownGuids: Set<String>) -> [Episode] {
        podcast.episodes.filter { !knownGuids.contains($0.guid) }
    }

    func refreshAll() async {
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isSubscribed })
        let podcasts = (try? modelContext.fetch(d)) ?? []
        for podcast in podcasts {
            let known = Set(podcast.episodes.map(\.guid))
            do {
                try await subscriptions.refreshEpisodes(for: podcast)
                if podcast.settings?.autoDownload == true {
                    for ep in newEpisodesAfterRefresh(for: podcast, knownGuids: known) {
                        downloads.download(ep)
                    }
                }
            } catch { continue }
        }
    }

    // MARK: Background task
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskId, using: nil) { task in
            let op = Task { await self.refreshAll(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { op.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/FeedRefreshServiceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Register + trigger refresh in the app**

In `Onda/OndaApp.swift`:
- add `@State private var refresh: FeedRefreshService` and `@Environment(\.scenePhase) private var scenePhase`
- in `init` after downloads: `_refresh = State(initialValue: FeedRefreshService(modelContext: c.mainContext, subscriptions: <subscriptions instance>, downloads: <downloads instance>))` — build `subscriptions`/`downloads` into locals first, then pass them to both their own `State(...)` and to `refresh`.
- add `BGTaskScheduler` permitted identifier `com.onda.refresh` to Info via `project.yml`: `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers: [com.onda.refresh]` under the `Onda` target, then `xcodegen generate`.
- call `refresh.registerBackgroundTask()` in `init`.
- add to the `WindowGroup` content: `.onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh.refreshAll() } } else if phase == .background { refresh.scheduleBackgroundRefresh() } }`

Concretely, the `init` becomes:

```swift
    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            AudioSession.activate()
            let subs = SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient())
            let persistence = PersistenceActor(modelContainer: c)
            let dm = DownloadManager(persistence: persistence)
            _subscriptions = State(initialValue: subs)
            _downloads = State(initialValue: dm)
            _playback = State(initialValue: PlaybackManager(engine: AVPlayerEngine(), modelContext: c.mainContext))
            let rs = FeedRefreshService(modelContext: c.mainContext, subscriptions: subs, downloads: dm)
            rs.registerBackgroundTask()
            _refresh = State(initialValue: rs)
        } catch { fatalError("Failed to build ModelContainer: \(error)") }
    }
```

- [ ] **Step 6: Build and run — verify foreground refresh + auto-download**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Launch, subscribe to an actively-updating show with Auto-Download on, background then foreground the app → `refreshAll` runs; any new episode auto-downloads and appears in Downloads & Storage.

- [ ] **Step 7: Commit**

```bash
git add Onda/Services/FeedRefreshService.swift OndaTests/FeedRefreshServiceTests.swift Onda/OndaApp.swift project.yml
git commit -m "feat: FeedRefreshService (foreground + BGAppRefreshTask) with auto-download"
```

---

### Task 6: Full regression pass

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: all tests across `ModelTests`, `ThemeTests`, `ITunesSearchClientTests`, `RSSFeedParserTests`, `SubscriptionServiceTests`, `PlaybackManagerTests`, `ChapterFetcherTests`, `BoostLevelTests`, `SilenceDetectorTests`, `AdWindowTests`, `DownloadStateTests`, `DownloadManagerTests`, `FeedRefreshServiceTests` PASS.

- [ ] **Step 2: Manual smoke test of the full app**

Launch and walk the whole flow: Discover → search → Follow → Library → Episode List → download an episode → play → Now Playing (scrubber, ±15/30, speed, boost, skip-silence, sleep timer, queue, chapters, settings gear) → lock screen controls → Downloads & Storage → delete → Profile appearance toggle (light/dark).

- [ ] **Step 3: Commit any fixes found, then tag**

```bash
git commit -am "fix: regression fixes from full smoke test" || true
git tag v0.1.0
```

---

## Self-Review

- **Spec coverage:** Episode downloads for offline playback ✓; background `URLSession` ✓; download progress + retry-once + manual retry ✓; SwiftData writes via `@ModelActor` (spec's threading fix) ✓; per-show settings sheet with every prototype control (speed/boost/silence/ad-skip/auto-download/intro-outro trim/notifications) ✓; Downloads & Storage manager screen (new) ✓; `FeedRefreshService` on foreground + `BGAppRefreshTask` ✓; auto-download for opted-in shows ✓.
- **Placeholder scan:** None. The one delegate/test-seam duality (`handleFinished`) is documented, not a stub. All code steps complete.
- **Type consistency:** `DownloadManager(persistence:session:)`, `state(for:)`, `download(_:)`, `delete(_:)`, `retryManually(guid:)`, `handleFinished(guid:tempURL:totalBytes:)`, `handleFailed(guid:)`, `PersistenceActor.recordDownload/deleteDownload`, `FeedRefreshService(modelContext:subscriptions:downloads:)`, `applyAudioSettings()` all match across tasks and the surfaces defined in Plans 3–4. `EpisodeRow(episode:onPlay:onDownload:)` matches Plan 2's definition.
