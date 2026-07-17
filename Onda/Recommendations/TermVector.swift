//  TermVector.swift
//  Bag-of-words tokenization and a weighted term vector with cosine + TF-IDF support — the
//  keyword half of recommendation similarity. Deliberately plain (regex split + stopwords, no
//  lemmatization) so it stays fast over large transcript text; semantic matching is layered on
//  top by the embedding scorer.
import Foundation

enum RecTokenizer {
    /// Common English function words plus podcast-boilerplate that carries no topic signal.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "with", "this", "that", "have",
        "from", "they", "was", "were", "will", "would", "there", "their", "what", "when", "which",
        "who", "how", "why", "our", "out", "get", "got", "can", "just", "like", "one", "all", "about",
        "into", "over", "then", "than", "them", "his", "her", "she", "him", "its", "been", "more",
        "some", "any", "had", "has", "did", "does", "were", "been", "also", "very", "much", "many",
        "podcast", "episode", "show", "listen", "listeners", "welcome", "today", "week", "talk",
        "talks", "hosted", "host", "hosts", "guest", "guests", "join", "new", "time", "way", "thing"
    ]

    static func terms(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }
}

struct TermVector: Equatable {
    private(set) var weights: [String: Double]

    init(_ weights: [String: Double] = [:]) { self.weights = weights }

    /// Accumulate `weight` for each token found in `text`.
    init(text: String, weight: Double = 1) {
        var w: [String: Double] = [:]
        for term in RecTokenizer.terms(in: text) { w[term, default: 0] += weight }
        weights = w
    }

    var terms: Set<String> { Set(weights.keys) }
    var isEmpty: Bool { weights.isEmpty }

    mutating func add(_ other: TermVector) {
        for (t, w) in other.weights { weights[t, default: 0] += w }
    }

    mutating func add(text: String, weight: Double) {
        for term in RecTokenizer.terms(in: text) { weights[term, default: 0] += weight }
    }

    /// Highest-weighted terms — used for explanations and for building iTunes queries.
    func topTerms(_ n: Int) -> [String] {
        weights.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(n).map(\.key)
    }

    func scaled(by idf: [String: Double]) -> TermVector {
        TermVector(weights.reduce(into: [:]) { $0[$1.key] = $1.value * (idf[$1.key] ?? 0) })
    }

    func cosine(_ other: TermVector) -> Double {
        guard !weights.isEmpty, !other.weights.isEmpty else { return 0 }
        var dot = 0.0
        // Iterate the smaller vector for the dot product.
        let (small, large) = weights.count <= other.weights.count
            ? (weights, other.weights) : (other.weights, weights)
        for (t, w) in small { if let o = large[t] { dot += w * o } }
        guard dot > 0 else { return 0 }
        let magA = sqrt(weights.values.reduce(0) { $0 + $1 * $1 })
        let magB = sqrt(other.weights.values.reduce(0) { $0 + $1 * $1 })
        return magA > 0 && magB > 0 ? dot / (magA * magB) : 0
    }

    /// Terms shared with `other`, ranked by this vector's weight — the "matched: …" reasons.
    func overlap(with other: TermVector, limit: Int) -> [String] {
        let shared = terms.intersection(other.terms)
        return shared.sorted { (weights[$0] ?? 0) > (weights[$1] ?? 0) }.prefix(limit).map { $0 }
    }
}

enum TFIDF {
    /// Inverse document frequency over a candidate corpus: rare-but-shared terms score higher.
    static func idf(documents: [TermVector]) -> [String: Double] {
        guard !documents.isEmpty else { return [:] }
        let n = Double(documents.count)
        var df: [String: Int] = [:]
        for doc in documents { for t in doc.terms { df[t, default: 0] += 1 } }
        return df.reduce(into: [:]) { $0[$1.key] = log((n + 1) / (Double($1.value) + 1)) + 1 }
    }
}
