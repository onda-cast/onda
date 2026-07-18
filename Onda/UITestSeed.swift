//  UITestSeed.swift
//  Seeds a deterministic library state for UI tests. Active only with UITEST_SEED_CLIP=1.
import Foundation
import SwiftData

@MainActor
enum UITestSeed {
    static var isActive: Bool { ProcessInfo.processInfo.environment["UITEST_SEED_CLIP"] == "1" }

    static func seed(context: ModelContext) {
        guard isActive else { return }
        // Playback state from a previously-run UI test survives relaunch (the seed reuses the
        // same episode guid), and restoreLastEpisode() would then float a mini-player whose
        // "UITest Show" text hijacks the tests' firstMatch taps. Clear it: every seeded launch
        // starts with no restorable episode.
        UserDefaults.standard.removeObject(forKey: PlaybackManager.lastEpisodeKey)
        // Wipe-and-reseed: stale seeds from earlier app versions must not leak into tests.
        let existing = (try? context.fetch(FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.title == "UITest Show" }))) ?? []
        for stale in existing { context.delete(stale) }   // cascades episodes/transcript/clips
        try? context.save()

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
        let settings = ShowSettings.makeDefault()
        settings.skipSilence = true       // exercise the silence detector in UI tests
        settings.podcast = pod; pod.settings = settings
        let ep = Episode(guid: "uitest-ep-1", title: "UITest Episode", publishDate: .now,
                         duration: 6, audioURL: URL(string: "https://uitest.local/e.mp3")!,
                         notes: "seeded")
        ep.podcast = pod; pod.episodes.append(ep)
        let file = DownloadedFile(localFileName: fileName, fileSizeBytes: 200_000, downloadedAt: .now)
        file.episode = ep; ep.downloadedFile = file
        let clip = Clip(startTime: 1, endTime: 3, text: "hello world this is a short test",
                        note: nil, createdAt: .now, needsReview: false)
        clip.episode = ep; ep.clips.append(clip)

        // Transcript cues roughly matching the fixture audio, so follow-along is testable.
        let tr = Transcript(source: "published", language: "en")
        tr.episode = ep; ep.transcript = tr
        let lines = ["Hello world.", "This is a test of skip silence.",
                     "The quiet parts should be jumped.", "And now we are done."]
        var cues: [TranscriptCue] = []
        for (i, line) in lines.enumerated() {
            let cue = TranscriptCue(startTime: Double(i) * 2.5, endTime: Double(i + 1) * 2.5,
                                    text: line, speaker: nil)
            cue.transcript = tr; cues.append(cue)
        }
        tr.cues = cues
        context.insert(tr)
        for c in cues { context.insert(c) }
        for m in [pod, ep] as [any PersistentModel] { context.insert(m) }
        context.insert(settings); context.insert(file); context.insert(clip)
        try? context.save()
    }
}
