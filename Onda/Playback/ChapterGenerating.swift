//  ChapterGenerating.swift
import Foundation

enum ChapterGenerationError: Error { case unavailable, noTranscript }

protocol ChapterGenerating: Sendable {
    func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter]
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
final class FoundationModelsChapterGenerator: ChapterGenerating {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct GeneratedChapters {
        @Guide(description: "3 to 8 chapter markers spanning the whole episode, ordered by time")
        let chapters: [GeneratedChapter]
    }

    @Generable
    struct GeneratedChapter {
        @Guide(description: "Short, descriptive chapter title (a few words)")
        let title: String
        @Guide(description: "Start time of this chapter in seconds from the beginning of the episode")
        let startTimeSeconds: Double
    }

    func generateChapters(transcriptText: String, duration: TimeInterval) async throws -> [ParsedChapter] {
        guard Self.isAvailable else { throw ChapterGenerationError.unavailable }
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChapterGenerationError.noTranscript
        }
        let session = LanguageModelSession()
        let prompt = """
        This is the transcript of a podcast episode that runs \(Int(duration)) seconds long. \
        Propose 3 to 8 chapter markers with short titles and start times (in seconds from the \
        start), spanning the whole episode from near 0 to near \(Int(duration)).

        Transcript:
        \(transcriptText.prefix(12_000))
        """
        let result = try await session.respond(to: prompt, generating: GeneratedChapters.self)
        return result.content.chapters
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { ParsedChapter(title: $0.title, startTime: $0.startTimeSeconds, isAd: false) }
    }
}
#endif
