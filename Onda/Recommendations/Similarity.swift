//  Similarity.swift
//  The hybrid content-similarity scorer: TF-IDF keyword cosine (precision) blended with on-device
//  NLEmbedding semantic cosine (recall). Gracefully drops to keyword-only when the embedding model
//  isn't available (we've seen NaturalLanguage asset flakiness — see docs/BUGS.md).
import Foundation
import NaturalLanguage

/// Abstracts NLEmbedding so scoring is testable without the (heavy, flaky) real model.
protocol WordEmbedding {
    func vector(for word: String) -> [Double]?
}

struct AppleWordEmbedding: WordEmbedding {
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    var isAvailable: Bool {
        embedding != nil
    }

    func vector(for word: String) -> [Double]? {
        embedding?.vector(for: word)
    }
}

enum EmbeddingSimilarity {
    /// Mean-pooled cosine between two term sets. nil when neither side embeds (→ keyword-only).
    static func score(_ a: Set<String>, _ b: Set<String>, using embedding: WordEmbedding) -> Double? {
        guard let va = meanVector(a, embedding), let vb = meanVector(b, embedding) else { return nil }
        return cosine(va, vb)
    }

    private static func meanVector(_ terms: Set<String>, _ embedding: WordEmbedding) -> [Double]? {
        var sum: [Double] = []
        var count = 0
        for term in terms {
            guard let v = embedding.vector(for: term) else { continue }
            if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
            count += 1
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, ma = 0.0, mb = 0.0
        for i in a.indices { dot += a[i] * b[i]; ma += a[i] * a[i]; mb += b[i] * b[i] }
        return ma > 0 && mb > 0 ? dot / (sqrt(ma) * sqrt(mb)) : 0
    }
}

enum HybridScorer {
    /// Weight on the keyword half; the embedding half gets the remainder when present.
    static let keywordWeight = 0.6

    /// Blend TF-IDF keyword cosine with embedding cosine. `idf` weights both vectors' keyword half.
    static func score(profile: TermVector, candidate: TermVector, idf: [String: Double],
                      embedding: WordEmbedding?) -> Double {
        let keyword = profile.scaled(by: idf).cosine(candidate.scaled(by: idf))
        guard let embedding,
              let semantic = EmbeddingSimilarity.score(profile.terms, candidate.terms, using: embedding)
        else { return keyword }
        return keywordWeight * keyword + (1 - keywordWeight) * semantic
    }
}
