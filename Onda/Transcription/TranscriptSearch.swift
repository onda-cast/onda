//  TranscriptSearch.swift
import Foundation
import SwiftData

struct TranscriptHit: Identifiable {
    var id: String { episodeGuid + "-\(startTime)" }
    let episodeGuid: String
    let episodeTitle: String
    let showTitle: String
    let cueText: String
    let startTime: TimeInterval
}

@MainActor
struct TranscriptSearch {
    private let modelContext: ModelContext
    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func search(_ query: String) -> [TranscriptHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let descriptor = FetchDescriptor<TranscriptCue>(
            predicate: #Predicate { $0.text.localizedStandardContains(q) })
        let cues = (try? modelContext.fetch(descriptor)) ?? []
        let hits = cues.compactMap { cue -> TranscriptHit? in
            guard let ep = cue.transcript?.episode, let pod = ep.podcast, pod.isSubscribed else { return nil }
            return TranscriptHit(episodeGuid: ep.guid, episodeTitle: ep.title,
                                 showTitle: pod.title, cueText: cue.text, startTime: cue.startTime)
        }
        return hits.sorted { ($0.showTitle, $0.startTime) < ($1.showTitle, $1.startTime) }
    }
}
