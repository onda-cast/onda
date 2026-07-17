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
        return results.compactMap { r -> TranscriptHit? in
            let guid = r.episodeGuid
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            guard let ep = (try? modelContext.fetch(descriptor))?.first,
                  let pod = ep.podcast, pod.isSubscribed else { return nil }
            return TranscriptHit(kind: r.kind, episodeGuid: ep.guid, episodeTitle: ep.title,
                                 showTitle: pod.title, cueText: r.snippet, startTime: r.startTime)
        }
    }
}
