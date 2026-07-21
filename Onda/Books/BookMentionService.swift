//  BookMentionService.swift
//  The Books Mentioned funnel for ONE episode: link + pattern + LLM candidates → the
//  OpenLibrary verification gate → persisted BookMention rows. Strictly single-episode and
//  user-initiated by design (see the spec): there is no batch entry point, and none may be
//  added — the feature answers "what was that book in THIS episode?", nothing broader.
import Foundation
import NaturalLanguage
import SwiftData

@MainActor
@Observable
final class BookMentionService {
    private let modelContext: ModelContext
    private let verifier: BookVerifier
    private let llm: BookExtracting?
    private let isPersonName: (String) -> Bool

    /// guid of the episode currently being processed (drives the sheet's progress state).
    private(set) var inFlightGuid: String?
    var lastFailure: String?

    init(modelContext: ModelContext, verifier: BookVerifier = BookVerifier(),
         llm: BookExtracting? = nil, isPersonName: ((String) -> Bool)? = nil) {
        self.modelContext = modelContext
        self.verifier = verifier
        self.llm = llm
        self.isPersonName = isPersonName ?? Self.nlPersonCheck
    }

    /// Runs the full funnel for exactly one episode; re-running replaces its results.
    func findBooks(for episode: Episode) async {
        guard episode.podcast?.isPrivateFeed != true else {
            lastFailure = "Books can't be looked up for private shows — their content never leaves this device."
            return
        }
        guard inFlightGuid == nil else { return }
        inFlightGuid = episode.guid
        lastFailure = nil
        defer { inFlightGuid = nil }

        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { (text: $0.text, start: $0.startTime) }

        var candidates = BookLinkParser.candidates(from: episode.noteLinks)
        let patterns = BookPatternExtractor(isPersonName: isPersonName)
        candidates += patterns.candidates(fromNotes: episode.notes)
        candidates += patterns.candidates(fromCues: cues)
        candidates += await llmCandidates(cues: cues)

        let verified = await Self.verifyConcurrently(candidates, with: verifier)

        guard !verified.isEmpty else {
            if candidates.isEmpty {
                lastFailure = "No book mentions found in this episode's notes or transcript."
            } else {
                lastFailure = "Couldn't verify any mentions — check your connection and try again."
            }
            return
        }

        replaceMentions(for: episode, with: verified)
    }

    /// Verifies every candidate against OpenLibrary concurrently — sequential awaits made
    /// "Find Books" take tens of seconds on episodes with many candidates (one round-trip
    /// at a time).
    private static func verifyConcurrently(_ candidates: [BookCandidate],
                                           with verifier: BookVerifier) async -> [(VerifiedBook, BookCandidate)] {
        await withTaskGroup(of: (VerifiedBook, BookCandidate)?.self) { group in
            for candidate in candidates {
                group.addTask {
                    guard let book = await verifier.verify(candidate) else { return nil }
                    return (book, candidate)
                }
            }
            var verified: [(VerifiedBook, BookCandidate)] = []
            for await result in group {
                if let result { verified.append(result) }
            }
            return verified
        }
    }

    /// Replace-on-rerun; dedupe by work key, preferring entries that carry a timestamp.
    /// Snapshot first: deleting a BookMention can mutate episode.bookMentions in place
    /// (cascade inverse), which would corrupt iteration over the live relationship array.
    private func replaceMentions(for episode: Episode, with verified: [(VerifiedBook, BookCandidate)]) {
        let existingMentions = episode.bookMentions
        for old in existingMentions { modelContext.delete(old) }
        episode.bookMentions.removeAll()
        var byKey: [String: (VerifiedBook, BookCandidate)] = [:]
        for (book, candidate) in verified {
            if let existing = byKey[book.workKey], existing.1.timestamp != nil { continue }
            byKey[book.workKey] = (book, candidate)
        }
        for (book, candidate) in byKey.values {
            let mention = BookMention(workKey: book.workKey, title: book.title, author: book.author,
                                      coverURL: book.coverURL,
                                      sourceTier: candidate.sourceTier,
                                      timestamp: candidate.timestamp)
            mention.episode = episode
            episode.bookMentions.append(mention)
            modelContext.insert(mention)
        }
        try? modelContext.save()
    }

    // LLM tier: chapter-sized chunks in, candidates with quote-recovered timestamps out.
    private func llmCandidates(cues: [(text: String, start: TimeInterval)]) async -> [BookCandidate] {
        guard let llm, !cues.isEmpty else { return [] }
        let fullText = cues.map(\.text).joined(separator: " ")
        let chunks = stride(from: 0, to: fullText.count, by: 10000).map {
            String(fullText.dropFirst($0).prefix(10000))
        }
        guard let found = try? await llm.bookCandidates(transcriptChunks: chunks) else { return [] }
        return found.map { c in
            BookCandidate(title: c.title, author: c.author, isbnOrASIN: nil,
                          timestamp: Self.timestamp(forQuote: c.nearbyQuote, in: cues),
                          sourceTier: "transcript")
        }
    }

    /// Recovers a cue timestamp by substring-matching the LLM's verbatim quote.
    static func timestamp(forQuote quote: String,
                          in cues: [(text: String, start: TimeInterval)]) -> TimeInterval? {
        let needle = quote.lowercased().trimmingCharacters(in: .whitespaces)
        guard needle.count >= 8 else { return nil }
        return cues.first { $0.text.lowercased().contains(needle) }?.start
    }

    /// Production person check (tests inject a deterministic closure instead — NL models
    /// are flaky in simulators, docs/BUGS.md #2).
    private static func nlPersonCheck(_ name: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = name
        var isPerson = false
        tagger.enumerateTags(in: name.startIndex ..< name.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .personalName { isPerson = true }
            return true
        }
        return isPerson
    }
}
