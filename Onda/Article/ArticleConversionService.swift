//  ArticleConversionService.swift
import Foundation
import SwiftData

/// Orchestrates URL → extracted article → sentences → rendered TTS audio → SwiftData rows.
/// In-flight state is ephemeral (app-kill loses it; the user re-adds the link). Rows are
/// only inserted after the full pipeline succeeds, so a half-finished conversion never
/// shows up as a broken episode.
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

    private let modelContext: ModelContext
    private let extract: Extract
    private let renderer: ArticleSpeechRendering
    private let persistTranscript: (Episode, [ParsedCue]) -> Void

    var pending: [Pending] = []

    /// Tracks the in-flight conversion Task per URL so dismiss() can cancel it and add() can
    /// tell "already converting" apart from "failed, needs a fresh attempt".
    private var tasks: [URL: Task<Void, Never>] = [:]

    init(modelContext: ModelContext, extract: @escaping Extract,
         renderer: ArticleSpeechRendering,
         persistTranscript: @escaping (Episode, [ParsedCue]) -> Void) {
        self.modelContext = modelContext
        self.extract = extract
        self.renderer = renderer
        self.persistTranscript = persistTranscript
    }

    func add(url: URL) {
        // Idempotent while in flight; re-adding a failed URL restarts it.
        if tasks[url] != nil { return }
        pending.removeAll { $0.id == url }
        pending.insert(Pending(id: url), at: 0)
        tasks[url] = Task { [weak self] in await self?.convert(url) }
    }

    func retry(url: URL) {
        pending.removeAll { $0.id == url }
        add(url: url)
    }

    func dismiss(url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        pending.removeAll { $0.id == url }
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

    func convert(_ url: URL) async {
        // Clears the in-flight marker on every exit path (success, failure, or cancellation),
        // including when convert() is invoked directly (tests, queue drain) without add().
        defer { tasks[url] = nil }
        setStage(url, .fetching)
        do {
            let article = try await extract(url)
            let sentences = SentenceSplitter.split(article.textContent)
            guard !sentences.isEmpty else { throw ArticleExtractionError.noReadableContent }

            setStage(url, .synthesizing(0))
            let guid = "article-\(UUID().uuidString)"
            let out = DownloadManager.fileURL(named: Self.audioFileName(for: guid))
            let rendered = try await renderer.render(
                sentences: sentences, voiceIdentifier: currentVoiceIdentifier(),
                outputURL: out,
                progress: { [weak self] p in
                    Task { @MainActor in self?.updateStage(url, .synthesizing(p)) }
                })
            // A dismiss() may have cancelled this Task while render() was finishing up; don't
            // resurrect the dismissed row with a freshly-inserted episode. render() already
            // succeeded, so clean up the now-orphaned audio file it wrote.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: out)
                pending.removeAll { $0.id == url }
                return
            }
            insertEpisode(guid: guid, url: url, article: article, rendered: rendered)
            pending.removeAll { $0.id == url }
        } catch {
            // The extractor maps cancellation to .timeout and the renderer throws
            // CancellationError, so check Task.isCancelled directly rather than the error type.
            // A cancelled conversion must not resurrect or fail-mark a dismissed row.
            guard !Task.isCancelled else {
                pending.removeAll { $0.id == url }
                return
            }
            setFailure(url, message: (error as? LocalizedError)?.errorDescription
                       ?? "Conversion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - private

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
    /// so the entry is created here if missing.
    private func setStage(_ url: URL, _ stage: Stage) {
        if let i = pending.firstIndex(where: { $0.id == url }) {
            pending[i].stage = stage
            pending[i].failure = nil
        } else {
            pending.insert(Pending(id: url, stage: stage), at: 0)
        }
    }

    /// Update-only: for progress ticks, which must never resurrect a row that dismiss() already
    /// removed (unlike setStage's upsert, used only for the two stage transitions in convert()).
    private func updateStage(_ url: URL, _ stage: Stage) {
        guard let i = pending.firstIndex(where: { $0.id == url }) else { return }
        pending[i].stage = stage
        pending[i].failure = nil
    }

    private func setFailure(_ url: URL, message: String) {
        guard let i = pending.firstIndex(where: { $0.id == url }) else { return }
        pending[i].failure = message
    }
}
