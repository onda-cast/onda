//  UITestSeed.swift
//  Seeds a deterministic library state for UI tests. Active only with UITEST_SEED_CLIP=1.
import Foundation
import SwiftData

@MainActor
enum UITestSeed {
    static var isActive: Bool { ProcessInfo.processInfo.environment["UITEST_SEED_CLIP"] == "1" }

    static func seed(context: ModelContext) {
        guard isActive else { return }
        // Idempotent: skip if already seeded.
        let existing = (try? context.fetch(FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.title == "UITest Show" }))) ?? []
        guard existing.isEmpty else { return }

        // Copy bundled audio into the Downloads dir so the clip has a local source.
        let fileName = "uitest_audio.m4a.aiff"
        let dest = DownloadManager.fileURL(named: fileName)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let src = Bundle.main.url(forResource: "uitest-audio", withExtension: "aiff") {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }

        let pod = Podcast(feedURL: URL(string: "https://uitest.local/feed.xml")!,
                          title: "UITest Show", author: "UITest", artworkURL: nil,
                          category: "Testing", itunesId: nil, isSubscribed: true)
        let ep = Episode(guid: "uitest-ep-1", title: "UITest Episode", publishDate: .now,
                         duration: 6, audioURL: URL(string: "https://uitest.local/e.mp3")!,
                         notes: "seeded")
        ep.podcast = pod; pod.episodes.append(ep)
        let file = DownloadedFile(localFileName: fileName, fileSizeBytes: 200_000, downloadedAt: .now)
        file.episode = ep; ep.downloadedFile = file
        let clip = Clip(startTime: 1, endTime: 3, text: "hello world this is a short test",
                        note: nil, createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip)
        for m in [pod, ep] as [any PersistentModel] { context.insert(m) }
        context.insert(file); context.insert(clip)
        try? context.save()
    }
}
