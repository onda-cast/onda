//  TranscriptSearch.swift
import Foundation
import SwiftData

struct TranscriptHit: Identifiable {
    var id: String { kind + "-" + episodeGuid + "-\(startTime)" }
    let kind: String            // "cue" | "clip"
    let episodeGuid: String
    let episodeTitle: String
    let showTitle: String
    let cueText: String
    let startTime: TimeInterval
}

@MainActor
struct TranscriptSearch {
    private let modelContext: ModelContext
    private let index: SearchIndex
    init(modelContext: ModelContext, index: SearchIndex) {
        self.modelContext = modelContext
        self.index = index
    }

    func search(_ query: String) -> [TranscriptHit] {
        let results = (try? index.search(query)) ?? []
        let guids = Array(Set(results.map { $0.episodeGuid }))
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { guids.contains($0.guid) })
        let episodes = (try? modelContext.fetch(descriptor)) ?? []
        let episodesByGuid = Dictionary(uniqueKeysWithValues: episodes.map { ($0.guid, $0) })
        return results.compactMap { r -> TranscriptHit? in
            guard let ep = episodesByGuid[r.episodeGuid],
                  let pod = ep.podcast, pod.isSubscribed else { return nil }
            return TranscriptHit(kind: r.kind, episodeGuid: ep.guid, episodeTitle: ep.title,
                                 showTitle: pod.title, cueText: r.snippet, startTime: r.startTime)
        }
    }
}
