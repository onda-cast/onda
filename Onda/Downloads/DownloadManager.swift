//  DownloadManager.swift
import Foundation
import SwiftData

protocol URLSessionProtocol { func downloadTask(with url: URL) -> URLSessionDownloadTask }
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
        states[guid] = .downloading(progress: 0)
        urlByGuid[guid] = episode.audioURL
        guidByTaskURL[episode.audioURL] = guid
        let task = session.downloadTask(with: episode.audioURL)
        task.resume()
    }

    func delete(_ episode: Episode) {
        let url = Self.fileURL(named: Self.fileName(for: episode.guid))
        try? FileManager.default.removeItem(at: url)
        states[episode.guid] = DownloadState.none
        let guid = episode.guid
        Task { [persistence] in try? await persistence.deleteDownload(episodeGuid: guid) }
    }

    // MARK: delegate seams (unit-tested directly)

    func handleFinished(guid: String, tempURL: URL, totalBytes: Int64) async {
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
    }

    func handleFailed(guid: String) {
        let attempts = (retries[guid] ?? 0) + 1
        retries[guid] = attempts
        if attempts <= 1, let url = urlByGuid[guid] {
            states[guid] = .downloading(progress: 0)   // auto-retry once
            session.downloadTask(with: url).resume()
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

    func updateProgress(guid: String, progress: Double) {
        // Throttle: delegate fires every few KB; re-rendering observers hundreds of times
        // per second makes the whole app feel sluggish during downloads.
        if case .downloading(let prev) = states[guid] ?? .none, abs(progress - prev) < 0.01 { return }
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
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
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

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let src = downloadTask.originalRequest?.url, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self, let guid = self.guidByTaskURL[src] else { return }
            self.updateProgress(guid: guid, progress: progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let src = task.originalRequest?.url else { return }
        Task { @MainActor [weak self] in
            guard let self, let guid = self.guidByTaskURL[src] else { return }
            self.handleFailed(guid: guid)
        }
    }
}
