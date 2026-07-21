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

    /// On-device runs currently executing, keyed by episode guid. A second `transcript(for:)`
    /// for the same guid attaches to the running task instead of starting a second engine pass
    /// (which would interleave progress writes and flicker the bar). Also lets a re-opened
    /// transcript sheet detect a backgrounded run and show its progress.
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// True while an on-device transcription is running for this episode.
    func isTranscribing(_ episode: Episode) -> Bool {
        inFlightTasks[episode.guid] != nil
    }

    // MARK: Background completion notice

    /// App-wide toast text shown when a backgrounded transcription finishes (see RootView).
    var completionNotice: String?
    private var notifyGuids: Set<String> = []
    private var noticeTask: Task<Void, Never>?

    /// "Continue in background": the user left the transcript sheet while transcription runs;
    /// post an in-app notice when this episode's run completes (or fails).
    func notifyOnCompletion(of episode: Episode) {
        notifyGuids.insert(episode.guid)
    }

    private func postNoticeIfRequested(guid: String, episodeTitle: String, success: Bool) {
        guard notifyGuids.remove(guid) != nil else { return }
        completionNotice = success ? "Transcript ready — \(episodeTitle)"
            : "Transcription failed — \(episodeTitle)"
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.completionNotice = nil }
        }
    }

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

    var hasEngine: Bool {
        engine != nil
    }

    func canTranscribeOnDevice(_ episode: Episode) -> Bool {
        engine != nil && localURL(episode) != nil
    }

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
            // Dedupe: attach to a run already in flight for this episode rather than starting a
            // second engine pass. Fixes the reopened-sheet "no progress" gap and the progress-bar
            // flicker from two concurrent runs writing progress[guid].
            // Transcript is a SwiftData PersistentModel (not Sendable), so the shared task can't
            // carry it across isolation — it persists to episode.transcript, which we read back
            // after awaiting.
            if let running = inFlightTasks[guid] {
                await running.value
                return episode.transcript
            }
            let task = Task { @MainActor [weak self] in
                _ = await self?.runOnDevice(engine: engine, file: file, episode: episode)
            }
            inFlightTasks[guid] = task
            defer { inFlightTasks[guid] = nil }
            await task.value
            return episode.transcript
        }
        return nil
    }

    private func runOnDevice(engine: AudioTranscribing, file: URL, episode: Episode) async -> Transcript? {
        let guid = episode.guid
        do {
            lastFailure[guid] = nil
            let cues = try await engine.transcribe(fileURL: file) { p in
                Task { @MainActor [weak self] in self?.progress[guid] = p }
            }
            progress[guid] = nil
            if !cues.isEmpty {
                let tr = persist(cues: cues, for: episode, source: "ondevice")
                postNoticeIfRequested(guid: guid, episodeTitle: episode.title, success: true)
                return tr
            }
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
        // Reached only on the failure paths (empty result or thrown) — success returned above.
        postNoticeIfRequested(guid: guid, episodeTitle: episode.title, success: false)
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

    /// Non-prompting check — auto-transcription must never trigger the permission dialog.
    nonisolated static var speechAuthorizationGranted: Bool {
        #if canImport(Speech)
            SFSpeechRecognizer.authorizationStatus() == .authorized
        #else
            false
        #endif
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
