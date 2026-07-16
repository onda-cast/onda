//  TranscriptService.swift
import Foundation
import SwiftData
#if canImport(Speech)
import Speech
#endif

@MainActor
@Observable
final class TranscriptService {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let modelContext: ModelContext
    private let parser: TranscriptParser
    private let engine: AudioTranscribing?
    private let fetch: Fetch
    private let localURL: (Episode) -> URL?

    var progress: [String: Double] = [:]

    init(modelContext: ModelContext, parser: TranscriptParser = .init(),
         engine: AudioTranscribing?,
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         localURL: @escaping (Episode) -> URL?) {
        self.modelContext = modelContext
        self.parser = parser
        self.engine = engine
        self.fetch = fetch
        self.localURL = localURL
    }

    var hasEngine: Bool { engine != nil }
    func canTranscribeOnDevice(_ episode: Episode) -> Bool { engine != nil && localURL(episode) != nil }

    func transcript(for episode: Episode) async -> Transcript? {
        if let existing = episode.transcript, !existing.cues.isEmpty { return existing }

        if let url = episode.transcriptURL {
            do {
                let data = try await fetch(url)
                let cues = parser.parse(data, type: episode.transcriptType ?? "")
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "published") }
            } catch { /* fall through to on-device */ }
        }

        if let engine, let file = localURL(episode) {
            let guid = episode.guid
            do {
                let cues = try await engine.transcribe(fileURL: file) { p in
                    Task { @MainActor [weak self] in self?.progress[guid] = p }
                }
                progress[guid] = nil
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "ondevice") }
            } catch { progress[guid] = nil }
        }
        return nil
    }

    @discardableResult
    func persist(cues: [ParsedCue], for episode: Episode, source: String) -> Transcript {
        let tr = Transcript(source: source,
                            language: Locale.current.language.languageCode?.identifier ?? "en")
        tr.episode = episode
        episode.transcript = tr
        modelContext.insert(tr)
        for pc in cues {
            let cue = TranscriptCue(startTime: pc.startTime, endTime: pc.endTime,
                                    text: pc.text, speaker: pc.speaker)
            cue.transcript = tr; tr.cues.append(cue)
            modelContext.insert(cue)
        }
        try? modelContext.save()
        return tr
    }

    // nonisolated: TCC delivers the completion on a background queue, so the closure must
    // not inherit this class's MainActor isolation (docs/BUGS.md #1 — dispatch_assert_queue trap).
    nonisolated static func requestSpeechAuthorization() async -> Bool {
        #if canImport(Speech)
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status == .authorized)
            }
        }
        #else
        return false
        #endif
    }
}
