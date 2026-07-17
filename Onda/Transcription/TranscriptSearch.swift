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

    /// Natural-language search: SmartQueryParser extracts terms/speaker/show, FTS5 retrieves
    /// by terms, then hits are post-filtered by show title and (for cues) the speaker
    /// recorded on the matching transcript cue.
    func smartSearch(_ raw: String, knownShows: [String]) -> [TranscriptHit] {
        let q = SmartQueryParser.parse(raw, knownShows: knownShows)
        // If parsing strips everything (filter-only queries), fall back to the raw text.
        let ftsText = q.terms.isEmpty ? raw : q.ftsQueryText
        var hits = search(ftsText)
        if let show = q.show {
            hits = hits.filter { $0.showTitle.caseInsensitiveCompare(show) == .orderedSame }
        }
        if let speaker = q.speaker {
            hits = hits.filter { hit in
                guard hit.kind == "cue" else { return true }   // clips carry no speaker
                return cueSpeaker(episodeGuid: hit.episodeGuid, startTime: hit.startTime)?
                    .localizedCaseInsensitiveContains(speaker) ?? false
            }
        }
        return hits
    }

    private func cueSpeaker(episodeGuid: String, startTime: TimeInterval) -> String? {
        let d = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == episodeGuid })
        guard let ep = try? modelContext.fetch(d).first else { return nil }
        return ep.transcript?.cues.first { abs($0.startTime - startTime) < 0.01 }?.speaker
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
