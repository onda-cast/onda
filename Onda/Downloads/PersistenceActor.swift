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
        // File I/O happens here, off the main actor: a retention sweep evicting many
        // episodes calls DownloadManager.delete in a tight synchronous loop, and that
        // loop must stay main-thread-cheap even for a show with a lot of episodes.
        try? FileManager.default.removeItem(at: DownloadManager.fileURL(named: file.localFileName))
        modelContext.delete(file)
        ep.downloadedFile = nil
        try modelContext.save()
    }
}
