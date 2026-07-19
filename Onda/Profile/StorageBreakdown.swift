//  StorageBreakdown.swift
//  Storage accounting for the Downloads & Storage screen: downloaded audio (real file sizes)
//  vs. transcripts (estimated from cue text, since transcripts are DB rows not files), split by
//  type overall and per podcast.
import Foundation

struct StoragePodcastRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let audioBytes: Int64
    let transcriptBytes: Int64
    var totalBytes: Int64 { audioBytes + transcriptBytes }
}

struct StorageBreakdown: Equatable, Sendable {
    var audioBytes: Int64 = 0
    var transcriptBytes: Int64 = 0
    var podcasts: [StoragePodcastRow] = []
    var totalBytes: Int64 { audioBytes + transcriptBytes }
}

import SwiftData

enum StorageCalculator {
    /// Off-main variant: the sync `breakdown(podcasts:)` faults every episode, transcript, and
    /// cue's text — thousands of SwiftData faults with a real library, which froze the screen
    /// when run on the main thread per render. This computes once in a background ModelContext
    /// and returns a Sendable value snapshot.
    static func breakdownInBackground(container: ModelContainer) async -> StorageBreakdown {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let pods = (try? context.fetch(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.isSubscribed }))) ?? []
            return breakdown(podcasts: pods)
        }.value
    }

    /// Rough on-disk cost of a transcript: the UTF-8 byte length of all its cue text.
    static func transcriptBytes(for episode: Episode) -> Int64 {
        guard let cues = episode.transcript?.cues else { return 0 }
        return cues.reduce(0) { $0 + Int64($1.text.utf8.count) }
    }

    static func audioBytes(for episode: Episode) -> Int64 {
        episode.downloadedFile?.fileSizeBytes ?? 0
    }

    static func breakdown(podcasts: [Podcast]) -> StorageBreakdown {
        var rows: [StoragePodcastRow] = []
        var totalAudio: Int64 = 0
        var totalTranscript: Int64 = 0
        for pod in podcasts {
            var audio: Int64 = 0
            var transcript: Int64 = 0
            for ep in pod.episodes {
                audio += audioBytes(for: ep)
                transcript += transcriptBytes(for: ep)
            }
            totalAudio += audio
            totalTranscript += transcript
            if audio > 0 || transcript > 0 {
                rows.append(StoragePodcastRow(id: pod.feedURL.absoluteString, title: pod.title,
                                              audioBytes: audio, transcriptBytes: transcript))
            }
        }
        rows.sort { $0.totalBytes > $1.totalBytes }
        return StorageBreakdown(audioBytes: totalAudio, transcriptBytes: totalTranscript, podcasts: rows)
    }
}
