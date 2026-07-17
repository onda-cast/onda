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
    private let index: SearchIndex?

    var progress: [String: Double] = [:]
    var lastFailure: [String: String] = [:]   // guid → human-readable reason

    init(modelContext: ModelContext, parser: TranscriptParser = .init(),
         engine: AudioTranscribing?,
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 },
         localURL: @escaping (Episode) -> URL?,
         index: SearchIndex? = nil) {
        self.modelContext = modelContext
        self.parser = parser
        self.engine = engine
        self.fetch = fetch
        self.localURL = localURL
        self.index = index
    }

    var hasEngine: Bool { engine != nil }
    func canTranscribeOnDevice(_ episode: Episode) -> Bool { engine != nil && localURL(episode) != nil }

    func transcript(for episode: Episode) async -> Transcript? {
        if let existing = episode.transcript, !existing.cues.isEmpty { return existing }

        if let url = episode.transcriptURL {
            do {
                let data = try await fetch(url)
                let type = episode.transcriptType ?? ""
                // Parse off the main actor — hour-long transcripts are hundreds of KB.
                let p = parser
                let cues = await Task.detached(priority: .userInitiated) {
                    p.parse(data, type: type)
                }.value
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "published") }
            } catch { /* fall through to on-device */ }
        }

        if let engine, let file = localURL(episode) {
            let guid = episode.guid
            do {
                lastFailure[guid] = nil
                let cues = try await engine.transcribe(fileURL: file) { p in
                    Task { @MainActor [weak self] in self?.progress[guid] = p }
                }
                progress[guid] = nil
                if !cues.isEmpty { return persist(cues: cues, for: episode, source: "ondevice") }
                lastFailure[guid] = "Transcription produced no text for this audio."
            } catch {
                progress[guid] = nil
                let ns = error as NSError
                if ns.domain == "SFSpeechErrorDomain" {
                    lastFailure[guid] = """
                        Couldn't get Apple's on-device speech model. Check your connection — \
                        and note the iOS Simulator often can't download it (a real device can).
                        """
                } else {
                    lastFailure[guid] = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
        return nil
    }

    @discardableResult
    func persist(cues: [ParsedCue], for episode: Episode, source: String) -> Transcript {
        // Reassigning episode.transcript alone leaves the old Transcript (and its cues)
        // orphaned in the context — SwiftData's cascade delete rule only fires on an
        // explicit delete, not a relationship reassignment. Delete it up front so
        // re-persisting (e.g. re-transcribing) doesn't leave dangling backing data.
        if let old = episode.transcript {
            modelContext.delete(old)
        }
        let tr = Transcript(source: source,
                            language: Locale.current.language.languageCode?.identifier ?? "en")
        tr.episode = episode
        episode.transcript = tr
        modelContext.insert(tr)
        // Build all cues first and assign the relationship ONCE — appending one-by-one to a
        // SwiftData relationship array is quadratic and hung the main thread on long episodes
        // (thousands of cues → watchdog kill).
        var built: [TranscriptCue] = []
        built.reserveCapacity(cues.count)
        for pc in cues {
            let cue = TranscriptCue(startTime: pc.startTime, endTime: pc.endTime,
                                    text: pc.text, speaker: pc.speaker, words: pc.words)
            modelContext.insert(cue)
            built.append(cue)
        }
        tr.cues = built
        if let index {
            try? index.deleteAll(episodeGuid: episode.guid, kind: "cue")
            for cue in built {
                try? index.upsert(SearchDoc(kind: "cue", episodeGuid: episode.guid,
                                            startTime: cue.startTime, body: cue.text))
            }
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
