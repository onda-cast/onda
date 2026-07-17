//  ChapterGenerationService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ChapterGenerationService {
    private let modelContext: ModelContext
    private let generator: ChapterGenerating?
    private let hasTranscript: (Episode) -> Bool
    private let transcriptText: (Episode) -> String?

    var isGenerating: [String: Bool] = [:]
    var lastFailure: [String: String] = [:]

    init(modelContext: ModelContext, generator: ChapterGenerating?,
         hasTranscript: @escaping (Episode) -> Bool,
         transcriptText: @escaping (Episode) -> String?) {
        self.modelContext = modelContext
        self.generator = generator
        self.hasTranscript = hasTranscript
        self.transcriptText = transcriptText
    }

    func canGenerate(_ episode: Episode) -> Bool {
        generator != nil && episode.chapters.isEmpty && hasTranscript(episode)
    }

    @discardableResult
    func generate(for episode: Episode) async -> [Chapter]? {
        guard let generator, let text = transcriptText(episode) else { return nil }
        guard episode.chapters.isEmpty else { return nil }
        let guid = episode.guid
        guard isGenerating[guid] != true else { return nil }
        isGenerating[guid] = true
        defer { isGenerating[guid] = false }
        do {
            lastFailure[guid] = nil
            let parsed = try await generator.generateChapters(transcriptText: text, duration: episode.duration)
            guard !parsed.isEmpty else {
                lastFailure[guid] = "Couldn't find distinct chapters in this episode."
                return nil
            }
            var built: [Chapter] = []
            built.reserveCapacity(parsed.count)
            for pc in parsed {
                let chapter = Chapter(title: pc.title, startTime: pc.startTime, isAd: false, source: "generated")
                modelContext.insert(chapter)
                built.append(chapter)
            }
            episode.chapters.append(contentsOf: built)
            try? modelContext.save()
            return built
        } catch {
            lastFailure[guid] = "Couldn't generate chapters: \(error.localizedDescription)"
            return nil
        }
    }
}
