//  TranscriptFind.swift
import Foundation

/// Pure in-transcript find logic (same idiom as ActiveCue: no SwiftData, no view state).
/// Matching is a case-insensitive substring scan — the transcript is already in memory,
/// so no FTS involvement.
enum TranscriptFind {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    /// Indices (into `texts`) of entries containing `query`, in order. Empty/whitespace
    /// queries match nothing.
    static func matchingIndices(query: String, in texts: [String]) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return texts.indices.filter { texts[$0].range(of: q, options: .caseInsensitive) != nil }
    }

    /// Splits `text` into consecutive runs marked match/non-match for every occurrence of
    /// `query` (case-insensitive). Segments always reassemble to the original text.
    static func segments(of text: String, query: String) -> [Segment] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [Segment(text: text, isMatch: false)] }
        var result: [Segment] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: q, options: .caseInsensitive, range: cursor ..< text.endIndex) {
            if r.lowerBound > cursor {
                result.append(Segment(text: String(text[cursor ..< r.lowerBound]), isMatch: false))
            }
            result.append(Segment(text: String(text[r]), isMatch: true))
            cursor = r.upperBound
        }
        if cursor < text.endIndex {
            result.append(Segment(text: String(text[cursor...]), isMatch: false))
        }
        return result.isEmpty ? [Segment(text: text, isMatch: false)] : result
    }
}
