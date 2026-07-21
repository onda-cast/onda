//  DownloadManager.swift
import Foundation
import SwiftData

protocol URLSessionProtocol { func downloadTask(with request: URLRequest) -> URLSessionDownloadTask }
extension URLSession: URLSessionProtocol {}

@MainActor
@Observable
final class DownloadManager: NSObject {
    private let persistence: PersistenceActor
    private var session: URLSessionProtocol!
    private var states: [String: DownloadState] = [:]     // keyed by episode guid
    private var retries: [String: Int] = [:]
    private var urlByGuid: [String: URL] = [:]
    private var guidByTaskURL: [URL: String] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    // Guids deleted while their download was in flight: a task can be past the point
    // cancel() stops it (already finished writing, callback just hasn't run yet) and still
    // land in handleFinished — this tombstone makes that landing a no-op instead of silently
    // resurrecting the file/row delete() just removed.
    private var pendingDeleteGuids: Set<String> = []

    /// Fired (with the episode guid) after a download lands on disk and is recorded.
    /// Wired in OndaApp to kick off auto-transcription when the resolved setting is on.
    var onDownloadCompleted: ((String) -> Void)?

    /// Bumped once per completed download. Views that cache a derived count (e.g. the Library
    /// "new episodes" badge, which counts unplayed *downloaded* episodes) observe this to
    /// recompute when a download lands while they're on screen.
    private(set) var completedDownloadCount = 0

    /// Wired in OndaApp to the Wi-Fi-only setting; consulted per download request so
    /// flipping the toggle applies immediately without recreating the background session.
    var cellularAllowed: () -> Bool = { true }

    nonisolated static let downloadsSubdir = "Downloads"

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
        // Idempotent: play-triggered downloads can race the download button and each other.
        if episode.downloadedFile != nil { return }
        if case .downloading = states[guid] { return }
        pendingDeleteGuids.remove(guid)
        states[guid] = .downloading(progress: 0)
        urlByGuid[guid] = episode.audioURL
        guidByTaskURL[episode.audioURL] = guid
        let task = session.downloadTask(with: makeRequest(for: episode.audioURL))
        activeTasks[guid] = task
        task.resume()
    }

    private func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = cellularAllowed()
        return request
    }

    func delete(_ episode: Episode) {
        let guid = episode.guid
        states[guid] = DownloadState.none
        // Cancel any in-flight download for this episode — without this, a still-downloading
        // task can finish and land in handleFinished after delete, silently re-creating the
        // file/row that was just removed (e.g. a retention sweep evicting a mid-download episode).
        if let task = activeTasks.removeValue(forKey: guid) {
            task.cancel()
            pendingDeleteGuids.insert(guid)
        }
        if let url = urlByGuid.removeValue(forKey: guid) { guidByTaskURL.removeValue(forKey: url) }
        // The actual file removal happens inside PersistenceActor (off the main actor) —
        // a retention sweep can call this once per evicted episode in a tight loop, and
        // that loop must not block on synchronous disk I/O.
        Task { [persistence] in try? await persistence.deleteDownload(episodeGuid: guid) }
    }

    // MARK: delegate seams (unit-tested directly)

    func handleFinished(guid: String, tempURL: URL, totalBytes: Int64) async {
        activeTasks[guid] = nil
        // Release the routing entries added in download() — otherwise every completed download
        // leaves a permanent entry in both maps for the life of this long-lived singleton.
        if let url = urlByGuid.removeValue(forKey: guid) { guidByTaskURL.removeValue(forKey: url) }
        if pendingDeleteGuids.remove(guid) != nil {
            try? FileManager.default.removeItem(at: tempURL)   // episode was deleted mid-download
            return
        }
        let dest = Self.fileURL(named: Self.fileName(for: guid))
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if dest != tempURL {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tempURL, to: dest)
        }
        states[guid] = .downloaded
        retries[guid] = nil
        try? await persistence.recordDownload(episodeGuid: guid,
                                              fileName: Self.fileName(for: guid), sizeBytes: totalBytes)
        completedDownloadCount += 1
        onDownloadCompleted?(guid)
    }

    func handleFailed(guid: String) {
        activeTasks[guid] = nil
        let attempts = (retries[guid] ?? 0) + 1
        retries[guid] = attempts
        if attempts <= 1, let url = urlByGuid[guid] {
            states[guid] = .downloading(progress: 0)   // auto-retry once
            let task = session.downloadTask(with: makeRequest(for: url))
            activeTasks[guid] = task
            task.resume()
        } else {
            states[guid] = .failed
        }
    }

    func retryManually(guid: String) {
        retries[guid] = 0
        if let url = urlByGuid[guid] {
            states[guid] = .downloading(progress: 0)
            let task = session.downloadTask(with: makeRequest(for: url))
            activeTasks[guid] = task
            task.resume()
        }
    }

    func updateProgress(guid: String, progress: Double) {
        // Throttle: delegate fires every few KB; re-rendering observers hundreds of times
        // per second makes the whole app feel sluggish during downloads.
        if case let .downloading(prev) = states[guid] ?? .none, abs(progress - prev) < 0.01 { return }
        states[guid] = .downloading(progress: progress)
    }

    nonisolated static func fileName(for guid: String) -> String {
        let safe = guid.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        return "\(safe).mp3"
    }

    nonisolated static func fileURL(named name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(downloadsSubdir)
        return dir.appendingPathComponent(name)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let src = downloadTask.originalRequest?.url else { return }
        let total = downloadTask.countOfBytesReceived
        // The temp file is only valid during this callback — move it synchronously,
        // then hand the final path to the main actor for state + persistence.
        let tmpHold = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        try? FileManager.default.moveItem(at: location, to: tmpHold)
        Task { @MainActor [weak self] in
            guard let self, let guid = self.guidByTaskURL[src] else { return }
            await self.handleFinished(guid: guid, tempURL: tmpHold, totalBytes: total)
        }
    }

    nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let src = downloadTask.originalRequest?.url, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self, let guid = self.guidByTaskURL[src] else { return }
            self.updateProgress(guid: guid, progress: progress)
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let src = task.originalRequest?.url else { return }
        Task { @MainActor [weak self] in
            guard let self, let guid = self.guidByTaskURL[src] else { return }
            self.handleFailed(guid: guid)
        }
    }
}
