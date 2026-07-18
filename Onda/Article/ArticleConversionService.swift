//  ArticleConversionService.swift
import Foundation
import SwiftData

/// Orchestrates URL → extracted article → sentences → rendered TTS audio → SwiftData rows.
/// Not-yet-converted URLs persist in the shared PendingArticlesQueue (App Group JSON) so
/// conversions survive app termination; visible progress state (`pending`) remains
/// ephemeral. Rows are only inserted after the full pipeline succeeds, so a half-finished
/// conversion never shows up as a broken episode.
@MainActor
@Observable
final class ArticleConversionService {
    enum Stage: Equatable { case fetching, synthesizing(Double) }

    struct Pending: Identifiable, Equatable {
        let id: URL
        var stage: Stage = .fetching
        var failure: String?
    }

    typealias Extract = @MainActor @Sendable (URL) async throws -> ExtractedArticle

    static let articlesFeedURL = URL(string: "onda-local:articles")!
    static let maxAutoAttempts = 3

    private let modelContext: ModelContext
    private let extract: Extract
    private let renderer: ArticleSpeechRendering
    private let persistTranscript: (Episode, [ParsedCue]) -> Void
    private let queue: PendingArticlesQueue

    var pending: [Pending] = []

    /// Identifies the current attempt for a URL, alongside its Task handle (nil when the
    /// generation was registered by a direct convert(_:) call rather than add()). Cleanup code
    /// throughout convert(_:generation:) compares its own id against `inFlight[url]?.id` before
    /// mutating shared state, so a superseded (cancelled/replaced) attempt can never clobber a
    /// newer one's task handle or Pending row — closing the URL-only-keyed race where a stale
    /// task's cleanup wiped out a replacement's bookkeeping.
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>?
    }

    private var inFlight: [URL: InFlight] = [:]

    init(modelContext: ModelContext, extract: @escaping Extract,
         renderer: ArticleSpeechRendering,
         persistTranscript: @escaping (Episode, [ParsedCue]) -> Void,
         queue: PendingArticlesQueue = .standard) {
        self.modelContext = modelContext
        self.extract = extract
        self.renderer = renderer
        self.persistTranscript = persistTranscript
        self.queue = queue
    }

    func add(url: URL) {
        // Idempotent while in flight; re-adding a failed URL restarts it.
        if inFlight[url] != nil { return }
        queue.append(url)
        pending.removeAll { $0.id == url }
        pending.insert(Pending(id: url), at: 0)
        let id = UUID()
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.convert(url, generation: id)
        }
        inFlight[url] = InFlight(id: id, task: task)
    }

    func retry(url: URL) {
        // A conversion already in flight owns the row; retrying it would either duplicate the
        // work (if we restarted) or strand a running conversion with no row (if we just cleared
        // it, since add() early-returns while something is in flight). Only a failed/absent row
        // is safe to clear and re-add.
        if inFlight[url] != nil { return }
        pending.removeAll { $0.id == url }
        add(url: url)
    }

    func dismiss(url: URL) {
        queue.remove(url)
        inFlight[url]?.task?.cancel()
        inFlight[url] = nil
        pending.removeAll { $0.id == url }
    }

    /// Foreground reconciliation: restart every durable entry under the auto-retry cap
    /// (idempotent — add() ignores URLs already in flight) and surface capped entries as
    /// failed rows that only a manual RETRY will run again. Replaces the old drain-once
    /// handoff: entries persist until success or explicit dismiss.
    func resumePersisted() {
        for entry in queue.entries() {
            if entry.attempts < Self.maxAutoAttempts {
                add(url: entry.url)
            } else if inFlight[entry.url] == nil,
                      !pending.contains(where: { $0.id == entry.url }) {
                pending.append(Pending(
                    id: entry.url,
                    failure: "Conversion failed \(entry.attempts) times — retry to try again."))
            }
        }
    }

    /// Find-or-create the synthetic Articles show. Re-subscribes a previously "deleted"
    /// one — adding an article always makes the show visible again.
    func articlesPodcast() -> Podcast {
        let target = Self.articlesFeedURL
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == target })
        if let existing = try? modelContext.fetch(d).first {
            existing.isSubscribed = true
            return existing
        }
        let pod = Podcast(feedURL: target, title: "Articles", author: "You",
                          artworkURL: nil, category: "Articles", itunesId: nil,
                          isSubscribed: true)
        pod.isLocal = true
        let settings = ShowSettings.makeDefault()
        settings.podcast = pod
        pod.settings = settings
        modelContext.insert(pod)
        return pod
    }

    nonisolated static func audioFileName(for guid: String) -> String {
        guid.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_",
                                  options: .regularExpression) + ".m4a"
    }

    /// Thin wrapper preserving the original test-facing signature: convert() can be invoked
    /// directly (tests, queue drain) without a prior add(). It mints its own generation id and
    /// registers it (with no Task handle, since it's running inline on the caller's Task) so the
    /// generation guards inside convert(_:generation:) behave identically to the add() path —
    /// and so a concurrent add() for the same URL correctly sees "already converting".
    func convert(_ url: URL) async {
        let id: UUID
        if let existing = inFlight[url] {
            id = existing.id
        } else {
            id = UUID()
            inFlight[url] = InFlight(id: id, task: nil)
        }
        await convert(url, generation: id)
    }

    // MARK: - private

    private func isCurrentGeneration(_ url: URL, _ id: UUID) -> Bool {
        inFlight[url]?.id == id
    }

    private func convert(_ url: URL, generation id: UUID) async {
        // Clears the in-flight marker on every exit path (success, failure, or cancellation) —
        // but only if this generation is still the current one for the URL. If a newer
        // generation has already replaced this entry (dismiss() + add() raced with this task's
        // cleanup), clearing it here would wipe out the replacement's task handle.
        defer { if isCurrentGeneration(url, id) { inFlight[url] = nil } }
        setStage(url, .fetching, generation: id)
        do {
            let article = try await extract(url)
            let sentences = SentenceSplitter.split(article.textContent)
            guard !sentences.isEmpty else { throw ArticleExtractionError.noReadableContent }

            setStage(url, .synthesizing(0), generation: id)
            let guid = "article-\(UUID().uuidString)"
            let out = DownloadManager.fileURL(named: Self.audioFileName(for: guid))
            let rendered = try await renderer.render(
                sentences: sentences, voiceIdentifier: currentVoiceIdentifier(),
                outputURL: out,
                progress: { [weak self] p in
                    Task { @MainActor in self?.updateStage(url, .synthesizing(p), generation: id) }
                })
            // A dismiss() may have cancelled this Task while render() was finishing up; don't
            // resurrect the dismissed row with a freshly-inserted episode. render() already
            // succeeded, so clean up the now-orphaned audio file it wrote.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: out)
                if isCurrentGeneration(url, id) { pending.removeAll { $0.id == url } }
                return
            }
            // Not cancelled, but a newer generation may have already taken over the row (e.g.
            // this convert() was invoked directly while add() also started a fresh attempt).
            // Don't let a superseded generation insert an episode into a row it no longer owns.
            guard isCurrentGeneration(url, id) else {
                try? FileManager.default.removeItem(at: out)
                return
            }
            insertEpisode(guid: guid, url: url, article: article, rendered: rendered)
            queue.remove(url)
            pending.removeAll { $0.id == url }
        } catch {
            // The extractor maps cancellation to .timeout and the renderer throws
            // CancellationError, so check Task.isCancelled directly rather than the error type.
            // A cancelled conversion must not resurrect or fail-mark a dismissed row.
            guard !Task.isCancelled else {
                if isCurrentGeneration(url, id) { pending.removeAll { $0.id == url } }
                return
            }
            if isCurrentGeneration(url, id) { queue.recordAttempt(url) }
            setFailure(url, message: (error as? LocalizedError)?.errorDescription
                       ?? "Conversion failed: \(error.localizedDescription)", generation: id)
        }
    }

    private func insertEpisode(guid: String, url: URL, article: ExtractedArticle,
                               rendered: RenderedArticleAudio) {
        let pod = articlesPodcast()
        let ep = Episode(guid: guid, title: article.title, publishDate: .now,
                         duration: rendered.duration, audioURL: rendered.fileURL,
                         notes: [article.byline, article.siteName].compactMap { $0 }
                             .joined(separator: " — "))
        ep.sourceType = "article"
        modelContext.insert(ep)
        ep.podcast = pod
        pod.episodes.append(ep)

        let src = ArticleSource(sourceURL: url, siteName: article.siteName, addedAt: .now)
        src.episode = ep
        ep.articleSource = src
        modelContext.insert(src)

        let attrs = try? FileManager.default.attributesOfItem(atPath: rendered.fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let file = DownloadedFile(localFileName: Self.audioFileName(for: guid),
                                  fileSizeBytes: size, downloadedAt: .now)
        file.episode = ep
        ep.downloadedFile = file
        modelContext.insert(file)

        persistTranscript(ep, rendered.cues)
        try? modelContext.save()
    }

    /// Reads the voice preference without creating the Articles show (it may not exist yet).
    private func currentVoiceIdentifier() -> String? {
        let target = Self.articlesFeedURL
        let d = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == target })
        return (try? modelContext.fetch(d).first)?.settings?.ttsVoiceIdentifier
    }

    /// Upserts: convert(_:) can be entered without a prior add(url:) (tests, queue drain),
    /// so the entry is created here if missing. Generation-guarded: a task suspended in
    /// extract() can resume after dismiss() + add() replaced it with a newer generation, and
    /// must not resurrect/overwrite the replacement's row.
    private func setStage(_ url: URL, _ stage: Stage, generation id: UUID) {
        guard isCurrentGeneration(url, id) else { return }
        if let i = pending.firstIndex(where: { $0.id == url }) {
            pending[i].stage = stage
            pending[i].failure = nil
        } else {
            pending.insert(Pending(id: url, stage: stage), at: 0)
        }
    }

    /// Update-only: for progress ticks, which must never resurrect a row that dismiss() already
    /// removed (unlike setStage's upsert, used only for the two stage transitions in convert()).
    /// Generation-guarded for the same reason as setStage.
    private func updateStage(_ url: URL, _ stage: Stage, generation id: UUID) {
        guard isCurrentGeneration(url, id), let i = pending.firstIndex(where: { $0.id == url })
        else { return }
        pending[i].stage = stage
        pending[i].failure = nil
    }

    private func setFailure(_ url: URL, message: String, generation id: UUID) {
        guard isCurrentGeneration(url, id), let i = pending.firstIndex(where: { $0.id == url })
        else { return }
        pending[i].failure = message
    }
}
