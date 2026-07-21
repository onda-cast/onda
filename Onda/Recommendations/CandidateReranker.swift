//  CandidateReranker.swift
//  Stage 2 of the funnel: cheap metadata pre-rank to pick the top-K, then fetch those feeds for
//  real content (description + recent episode titles/notes) and score hybrid similarity.
import Foundation

@MainActor
struct CandidateReranker {
    let feeds: FeedFetching
    let embedding: WordEmbedding?
    var feedEpisodeSampleCount = 6

    /// Cheap score from only the metadata iTunes returns — used to choose which feeds to fetch.
    static func prescore(_ dto: PodcastDTO, profile: TasteProfile) -> Double {
        let meta = "\(dto.collectionName) \(dto.artistName) \(dto.primaryGenreName ?? "")"
        var score = profile.terms.cosine(TermVector(text: meta))
        if let genre = dto.primaryGenreName, profile.categories[genre] != nil { score += 0.3 }
        if profile.authors[dto.artistName] != nil { score += 0.3 }
        return score
    }

    func rank(profile: TasteProfile, candidates: [PodcastDTO], limit: Int = 15) async -> [Recommendation] {
        let top = candidates
            .sorted { Self.prescore($0, profile: profile) > Self.prescore($1, profile: profile) }
            .prefix(limit)

        // Fetch feeds concurrently (only ~15, but sequential awaits made this scale with
        // candidate count); a failed fetch falls back to metadata text.
        let tasks = top.map { dto in
            Task { @MainActor in await (dto, self.candidateVector(dto)) }
        }
        var docs: [(dto: PodcastDTO, vector: TermVector)] = []
        for task in tasks { await docs.append(task.value) }

        let idf = TFIDF.idf(documents: docs.map(\.vector))
        let scored = docs.map { doc -> Recommendation in
            let score = HybridScorer.score(profile: profile.terms, candidate: doc.vector,
                                           idf: idf, embedding: embedding)
            return Recommendation(dto: doc.dto, score: score,
                                  reasons: reasons(for: doc.dto, candidate: doc.vector, profile: profile))
        }
        return scored.sorted { $0.score > $1.score }
    }

    private func candidateVector(_ dto: PodcastDTO) async -> TermVector {
        var vector = TermVector(text: "\(dto.collectionName) \(dto.primaryGenreName ?? "")")
        if let feed = dto.feedUrl, let parsed = try? await feeds.fetchFeed(feed) {
            vector.add(text: parsed.title, weight: 1)
            for ep in parsed.episodes.prefix(feedEpisodeSampleCount) {
                vector.add(text: ep.title, weight: 1)
                vector.add(text: String(ep.notes.prefix(400)), weight: 0.5)
            }
        }
        return vector
    }

    private func reasons(for dto: PodcastDTO, candidate: TermVector, profile: TasteProfile) -> [String] {
        var out: [String] = []
        // Only surface clean vocabulary (genres/authors/searches), never raw transcript tokens.
        let vocab = TermVector(profile.displayVocabulary.reduce(into: [:]) { $0[$1] = 1 })
        let shared = candidate.overlap(with: vocab, limit: 3)
        if !shared.isEmpty { out.append("Matches your interest in \(shared.joined(separator: ", "))") }
        if let genre = dto.primaryGenreName, profile.categories[genre] != nil {
            out.append("More \(genre) like you follow")
        }
        if profile.authors[dto.artistName] != nil {
            out.append("From \(dto.artistName), who you already follow")
        }
        if out.isEmpty { out.append("Popular pick you might like") }
        return out
    }
}
