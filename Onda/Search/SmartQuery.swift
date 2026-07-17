//  SmartQuery.swift
//  Natural-language-ish search parsing: "book mentioned by michael in Odd Lots"
//  → terms=["book"], speaker="Michael", show="Odd Lots".
//  Pure + structured so a future on-device LLM parser can replace this tier without
//  touching retrieval (SearchIndex FTS5) or UI.
import Foundation

struct SmartQuery: Equatable, Sendable {
    var terms: [String]
    var speaker: String?
    var show: String?

    /// Plain text handed to SearchIndex.search (FTS5 MATCH is built there).
    var ftsQueryText: String { terms.joined(separator: " ") }
}

enum SmartQueryParser {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "in", "on", "of", "by", "from", "about", "was", "is", "are",
        "what", "which", "who", "when", "that", "did", "say", "said", "mentioned",
        "mention", "talked", "talking", "podcast", "podcasts", "episode", "episodes",
        "show", "and", "or", "to", "for", "with",
    ]

    static func parse(_ raw: String, knownShows: [String]) -> SmartQuery {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var show: String?
        var speaker: String?

        // Show: longest known title appearing case-insensitively wins; remove it.
        for candidate in knownShows.sorted(by: { $0.count > $1.count }) {
            if let r = text.range(of: candidate, options: [.caseInsensitive]) {
                show = candidate
                text.removeSubrange(r)
                break
            }
        }

        // Speaker: "by <Name>" / "from <Name>" — take the capitalized-or-not next word.
        if let match = text.range(of: #"\b(?:by|from)\s+([A-Za-z]+)"#,
                                  options: .regularExpression) {
            let phrase = String(text[match])
            if let name = phrase.split(separator: " ").last {
                speaker = String(name).capitalized
                text.removeSubrange(match)
            }
        }

        let terms = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }

        return SmartQuery(terms: terms, speaker: speaker, show: show)
    }
}
