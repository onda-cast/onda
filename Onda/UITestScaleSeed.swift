//  UITestScaleSeed.swift
//  Seeds a LARGE deterministic library (many shows/episodes, a few downloads) so perf probes
//  can reproduce device-scale Library behavior in the simulator. UITEST_SEED_SCALE=1 only.
import Foundation
import SwiftData

@MainActor
enum UITestScaleSeed {
    static var isActive: Bool { ProcessInfo.processInfo.environment["UITEST_SEED_SCALE"] == "1" }

    static let showCount = 25
    static let episodesPerShow = 120   // 3000 episodes total
    static let downloadCount = 12

    static func seed(context: ModelContext) {
        guard isActive else { return }
        let existing = (try? context.fetch(FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.author == "ScaleSeed" }))) ?? []
        guard existing.count < showCount else { return }   // already seeded; keep launches fast
        for stale in existing { context.delete(stale) }

        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var downloadsLeft = downloadCount
        for s in 0..<showCount {
            let pod = Podcast(feedURL: URL(string: "https://scale.local/\(s).xml")!,
                              title: String(format: "Scale Show %02d", s), author: "ScaleSeed",
                              artworkURL: nil, category: "Testing", itunesId: nil, isSubscribed: true)
            context.insert(pod)
            var eps: [Episode] = []
            for e in 0..<episodesPerShow {
                let ep = Episode(guid: "scale-\(s)-\(e)",
                                 title: "Scale \(s)-\(e)",
                                 publishDate: base.addingTimeInterval(Double(-(e * 86_400 + s))),
                                 duration: 1800, audioURL: URL(string: "https://scale.local/\(s)/\(e).mp3")!,
                                 notes: "Episode notes \(s)-\(e)", played: e % 3 == 0)
                context.insert(ep)
                eps.append(ep)
                // Spread a few downloads across the library, incl. some recent-and-unplayed
                // so every chip has matches (worst case scans farthest without them).
                if downloadsLeft > 0 && e == s % 5 {
                    let df = DownloadedFile(localFileName: "scale-\(s)-\(e).mp3",
                                            fileSizeBytes: 1_000, downloadedAt: base)
                    df.episode = ep; ep.downloadedFile = df
                    context.insert(df)
                    downloadsLeft -= 1
                }
            }
            pod.episodes.append(contentsOf: eps)
            for ep in eps { ep.podcast = pod }
        }
        try? context.save()
    }
}
