//  BookExtracting.swift
//  Tier 3: on-device LLM extraction of conversational book mentions. Same framework,
//  availability gate, and protocol-behind-a-fake pattern as FoundationModelsChapterGenerator.
import Foundation

struct LLMBookCandidate: Equatable, Sendable {
    let title: String
    let author: String?
    let nearbyQuote: String   // short verbatim phrase near the mention — matched back to a cue
}

enum BookExtractionError: Error { case unavailable }

protocol BookExtracting: Sendable {
    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate]
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
final class FoundationModelsBookExtractor: BookExtracting {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct ExtractedBooks {
        @Guide(description: "Every real, published book explicitly mentioned by title in the text. Empty if none.")
        let books: [ExtractedBook]
    }

    @Generable
    struct ExtractedBook {
        @Guide(description: "The book's title exactly as commonly published")
        let title: String
        @Guide(description: "The author's name if stated or well known, otherwise empty")
        let author: String
        @Guide(description: "A short verbatim phrase (5-12 words) copied from the text near the mention")
        let nearbyQuote: String
    }

    func bookCandidates(transcriptChunks: [String]) async throws -> [LLMBookCandidate] {
        guard Self.isAvailable else { throw BookExtractionError.unavailable }
        var out: [LLMBookCandidate] = []
        for chunk in transcriptChunks {
            let session = LanguageModelSession()
            let prompt = """
            List every real, published book that is explicitly mentioned by title in this \
            podcast transcript excerpt. Do not guess or infer books that are only alluded to. \
            If none are mentioned, return an empty list.

            Excerpt:
            \(chunk.prefix(12_000))
            """
            let result = try await session.respond(to: prompt, generating: ExtractedBooks.self)
            out.append(contentsOf: result.content.books.map {
                LLMBookCandidate(title: $0.title,
                                 author: $0.author.isEmpty ? nil : $0.author,
                                 nearbyQuote: $0.nearbyQuote)
            })
        }
        return out
    }
}
#endif
