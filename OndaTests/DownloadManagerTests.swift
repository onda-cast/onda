//  DownloadManagerTests.swift
import XCTest
import SwiftData
@testable import Onda

// Minimal fake: DownloadManager tests drive completion via handleFinished/handleFailed.
final class FakeURLSession: URLSessionProtocol {
    func downloadTask(with url: URL) -> URLSessionDownloadTask {
        URLSession(configuration: .default).downloadTask(with: url)
    }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    private struct TestEnv {
        let context: ModelContext
        let persistence: PersistenceActor
        let episode: Episode
    }

    private func makeEnv() throws -> TestEnv {
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
        return TestEnv(context: ctx, persistence: actor, episode: ep)
    }

    func test_download_setsDownloadingState() throws {
        let env = try makeEnv()
        let dm = DownloadManager(persistence: env.persistence, session: FakeURLSession())
        dm.download(env.episode)
        if case .downloading = dm.state(for: env.episode) {} else { XCTFail("expected downloading") }
    }

    func test_finished_writesFileAndMarksDownloaded() async throws {
        let env = try makeEnv()
        let dm = DownloadManager(persistence: env.persistence, session: FakeURLSession())
        dm.download(env.episode)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t.mp3")
        try Data([0, 1, 2, 3]).write(to: tmp)
        await dm.handleFinished(guid: "g1", tempURL: tmp, totalBytes: 4)
        XCTAssertEqual(dm.state(for: env.episode), .downloaded)
        // Persistence wrote a DownloadedFile (separate actor context → refetch)
        try await Task.sleep(for: .milliseconds(50))
        let refreshed = try env.context.fetch(FetchDescriptor<Episode>()).first
        XCTAssertNotNil(refreshed?.downloadedFile)
    }

    func test_failure_retriesOnce_thenFails() throws {
        let env = try makeEnv()
        let dm = DownloadManager(persistence: env.persistence, session: FakeURLSession())
        dm.download(env.episode)
        dm.handleFailed(guid: "g1")     // first failure → retry
        if case .downloading = dm.state(for: env.episode) {} else { XCTFail("expected retry (downloading)") }
        dm.handleFailed(guid: "g1")     // second failure → failed
        XCTAssertEqual(dm.state(for: env.episode), .failed)
    }

    // A retention sweep over many episodes calls delete() in a tight synchronous loop
    // (EpisodeRetentionService). If the file removal happens inline on the caller's
    // actor, that loop blocks the main thread for the whole sweep on a show with a lot
    // of downloaded episodes. The file must still be on disk right after delete()
    // returns — proving the removal was deferred off the synchronous call path — and
    // gone only once the deferred work has actually run.
    func test_delete_removesFileAsynchronously_notOnCallingThread() async throws {
        let env = try makeEnv()
        let dm = DownloadManager(persistence: env.persistence, session: FakeURLSession())
        let fileName = DownloadManager.fileName(for: "g1")
        let fileURL = DownloadManager.fileURL(named: fileName)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: fileURL)
        let file = DownloadedFile(localFileName: fileName, fileSizeBytes: 3, downloadedAt: .now)
        file.episode = env.episode; env.episode.downloadedFile = file
        env.context.insert(file); try env.context.save()

        dm.delete(env.episode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "file removal must be deferred, not run synchronously on the caller's actor")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "file is still removed, just off the synchronous call path")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
