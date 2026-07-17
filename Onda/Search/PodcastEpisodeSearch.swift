//  PodcastEpisodeSearch.swift
import Foundation

/// One matching episode for an in-show search. `snippet` (and `snippetStartTime`) are
/// populated only when the match came from the transcript FTS index; a title/notes-only
/// match leaves them nil.
struct EpisodeSearchResult: Identifiable {
    var id: String { episode.guid }
    let episode: Episode
    let snippet: String?
    let snippetStartTime: TimeInterval?
}

/// Per-podcast episode search over title, show-notes, and (when present) transcript text.
/// Deliberately avoids `SmartQueryParser`/NLTagger — the show is already fixed by context,
/// so plain keyword matching is enough and sidesteps the NL-asset flakiness (docs/BUGS.md).
@MainActor
struct PodcastEpisodeSearch {
    let index: SearchIndex?

    func search(_ query: String, in podcast: Podcast) -> [EpisodeSearchResult] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }

        let episodes = podcast.episodes.filter { !$0.isArchived }

        // Transcript hits: first matching cue/clip per episode guid, ordered by bm25.
        var snippetByGuid: [String: (text: String, start: TimeInterval)] = [:]
        let podcastGuids = Set(episodes.map(\.guid))
        if let index, let hits = try? index.search(query) {
            for hit in hits where podcastGuids.contains(hit.episodeGuid)
            && snippetByGuid[hit.episodeGuid] == nil {
                snippetByGuid[hit.episodeGuid] = (hit.snippet, hit.startTime)
            }
        }

        let matches = episodes.filter { ep in
            matchesMetadata(ep, terms: terms) || snippetByGuid[ep.guid] != nil
        }

        return matches
            .sorted { $0.publishDate > $1.publishDate }
            .map { ep in
                let hit = snippetByGuid[ep.guid]
                return EpisodeSearchResult(episode: ep, snippet: hit?.text,
                                           snippetStartTime: hit?.start)
            }
    }

    /// Every term must appear (case-insensitive) in the title or notes.
    private func matchesMetadata(_ ep: Episode, terms: [String]) -> Bool {
        let title = ep.title.lowercased()
        let notes = ep.notes.lowercased()
        return terms.allSatisfy { title.contains($0) || notes.contains($0) }
    }
}
