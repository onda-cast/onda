//  SmartQuery.swift
//  Natural-language-ish search parsing: "book mentioned by michael in Odd Lots"
//  → terms=["book"], speaker="Michael", show="Odd Lots".
//  NLTagger tier: person-name recognition, multi-word names, lemmatized terms,
//  POS-based function-word filtering. Pure + structured so a future on-device LLM
//  parser can replace this tier without touching retrieval (SearchIndex) or UI.
import Foundation
import NaturalLanguage

struct SmartQuery: Equatable, Sendable {
    var terms: [String]
    var speaker: String?
    var show: String?

    /// Plain text handed to SearchIndex.search (FTS5 MATCH is built there).
    var ftsQueryText: String {
        terms.joined(separator: " ")
    }
}

enum SmartQueryParser {
    /// Question/filler words that survive POS filtering but carry no search signal.
    private static let stopwords: Set<String> = [
        "podcast", "episode", "mention", "say", "talk", "thing", "one", "way",
        // POS tagging is unreliable on dangling fragments (post show/speaker removal),
        // so common function words get a literal backstop too.
        "in", "on", "of", "by", "from", "about", "at", "with", "for", "to", "the", "a", "an"
    ]
    /// Lexical classes that never contribute search terms. .verb and .interjection are
    /// intentionally NOT dropped: fragment tagging mislabels content nouns as both (e.g.
    /// trailing "quote" → Interjection) — the stoplists above catch true filler instead.
    private static let droppedClasses: Set<NLTag> = [
        .determiner, .preposition, .pronoun, .conjunction, .particle,
        .classifier, .idiom, .adverb
    ]

    static func parse(_ raw: String, knownShows: [String]) -> SmartQuery {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var show: String?

        // 1. Show: longest known title appearing case-insensitively wins; remove it.
        // Word-boundary matched (\b...\b), not a bare substring search — otherwise a short
        // show title can match inside an unrelated word (e.g. a show titled "It" matching
        // inside "quit"), incorrectly stripping text out of the search terms.
        for candidate in knownShows.sorted(by: { $0.count > $1.count }) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: candidate))\\b"
            if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                show = candidate
                text.removeSubrange(r)
                break
            }
        }

        // 2. Speaker: explicit "by/from <Name...>" phrasing wins (works lowercase too),
        //    else NLTagger named-entity recognition over the original-cased text.
        var speaker: String?
        if let match = text.range(
            of: #"\b(?:by|from)\s+([A-Z][A-Za-z]*(?:\s+[A-Z][A-Za-z]*)*|[a-z]+)"#,
            options: .regularExpression
        ) {
            let phrase = String(text[match])
            let name = phrase.split(separator: " ").dropFirst().joined(separator: " ")
            if !name.isEmpty {
                speaker = name.capitalized
                text.removeSubrange(match)
            }
        }
        if speaker == nil, let (name, range) = personName(in: text) {
            speaker = name
            text.removeSubrange(range)
        }

        // 3. Terms: lemmatize + POS-filter what's left.
        let terms = contentTerms(in: text)
        return SmartQuery(terms: terms, speaker: speaker, show: show)
    }

    /// First personal name NLTagger finds (multi-word names are contiguous .personalName tags).
    private static func personName(in text: String) -> (String, Range<String.Index>)? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var nameStart: String.Index?
        var nameEnd: String.Index?
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                if nameStart == nil { nameStart = range.lowerBound }
                nameEnd = range.upperBound
                return true
            }
            return nameStart == nil   // stop once a name run has ended
        }
        guard let s = nameStart, let e = nameEnd else { return nil }
        return (String(text[s ..< e]), s ..< e)
    }

    private static func contentTerms(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var terms: [String] = []
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .word,
                             scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, droppedClasses.contains(tag) { return true }
            let word = String(text[range])
            // Auxiliary/question verbs come through tagged inconsistently on fragments;
            // a tiny stoplist catches what POS filtering misses.
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?
                .rawValue.lowercased() ?? word.lowercased()
            let auxiliaries: Set = ["be", "do", "have", "will", "would", "can",
                                    "could", "should", "what", "which", "who",
                                    "when", "where", "how", "why"]
            guard !auxiliaries.contains(lemma), !stopwords.contains(lemma),
                  lemma.count > 1 else { return true }
            terms.append(lemma)
            return true
        }
        return terms
    }
}
