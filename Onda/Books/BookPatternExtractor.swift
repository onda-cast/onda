//  BookPatternExtractor.swift
//  Tier 2: explicit textual book references — quoted "Title" by Person, and
//  "Books mentioned:" list blocks. High precision, low recall, no ML beyond the
//  injected person check (NLTagger in production; a fixture closure in tests).
import Foundation

struct BookPatternExtractor {
    /// True when the string is a person's name. Injected: NLTagger-backed in the app,
    /// deterministic in tests (NL models are flaky in simulators — docs/BUGS.md #2).
    var isPersonName: (String) -> Bool

    func candidates(fromNotes notes: String) -> [BookCandidate] {
        quotedByPatterns(in: notes, tier: "notes", timestamp: nil)
            + authorOfBookPatterns(in: notes, tier: "notes", timestamp: nil)
            + readingListBlock(in: notes)
    }

    func candidates(fromCues cues: [(text: String, start: TimeInterval)]) -> [BookCandidate] {
        cues.flatMap {
            quotedByPatterns(in: $0.text, tier: "transcript", timestamp: $0.start)
                + authorOfBookPatterns(in: $0.text, tier: "transcript", timestamp: $0.start)
        }
    }

    // "author of [the] [new] book <Title>" — the common show-notes construction where the person
    // is introduced first and the (unquoted) title runs to the next clause boundary, e.g.
    // "...author of the new book Blood & Progress, which argues...". Title-only candidate: the
    // OpenLibrary gate resolves the author and rejects anything that isn't a real book, so the
    // low delimiting precision (no quotes) is safe. Case-insensitive on the connective phrase only
    // — the title itself must start with a capital so we don't grab a lowercase fragment.
    private func authorOfBookPatterns(in text: String, tier: String,
                                      timestamp: TimeInterval?) -> [BookCandidate] {
        let pattern = "(?i:(?:author|co-?author|wrote)\\s+of\\s+"
            + "(?:the\\s+|his\\s+|her\\s+|their\\s+|a\\s+)?"
            + "(?:new\\s+|latest\\s+|recent\\s+|debut\\s+|bestselling\\s+|best-selling\\s+|"
            + "upcoming\\s+|forthcoming\\s+|acclaimed\\s+|award-winning\\s+)*"
            + "book,?\\s+(?:titled\\s+|called\\s+|entitled\\s+)?[\"\u{201C}]?)"
            + "([A-Z][^,.;:\n\"\u{201C}\u{201D}]{1,80})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard title.count >= 2 else { return nil }
                return BookCandidate(title: title, author: nil, isbnOrASIN: nil,
                                     timestamp: timestamp, sourceTier: tier)
            }
    }

    // "<Title>" by <Capitalized Name>
    private func quotedByPatterns(in text: String, tier: String,
                                  timestamp: TimeInterval?) -> [BookCandidate] {
        let pattern = "[\"\u{201C}]([^\"\u{201C}\u{201D}]{2,80})[\"\u{201D}]\\s+by\\s+([A-Z][\\w.\\-]+(?:\\s+[A-Z][\\w.\\-]+){0,3})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let author = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                guard isPersonName(author) else { return nil }
                return BookCandidate(title: title, author: author, isbnOrASIN: nil,
                                     timestamp: timestamp, sourceTier: tier)
            }
    }

    // "Books mentioned:" / "Reading list:" header, then "Title — Author" (or "Title - Author") lines.
    private func readingListBlock(in notes: String) -> [BookCandidate] {
        let lines = notes.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { line in
            let l = line.lowercased()
            return l.contains("books mentioned") || l.contains("reading list")
        }) else { return [] }
        var out: [BookCandidate] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }   // blank line ends the block
            let separators = [" \u{2014} ", " \u{2013} ", " - "]
            guard let sep = separators.first(where: { trimmed.contains($0) }) else { continue }
            let parts = trimmed.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            out.append(BookCandidate(title: parts[0].trimmingCharacters(in: .whitespaces),
                                     author: parts[1].trimmingCharacters(in: .whitespaces),
                                     isbnOrASIN: nil, timestamp: nil, sourceTier: "notes"))
        }
        return out
    }
}
