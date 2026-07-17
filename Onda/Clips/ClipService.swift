//  ClipService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ClipService {
    static let quickClipWindow: TimeInterval = 45
    private let modelContext: ModelContext
    private let index: SearchIndex?

    init(modelContext: ModelContext, index: SearchIndex? = nil) {
        self.modelContext = modelContext
        self.index = index
    }

    @discardableResult
    func makeClip(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval,
                  note: String?, needsReview: Bool) -> Clip {
        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { CueSpan(start: $0.startTime, end: $0.endTime, text: $0.text) }
        let snapped = ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                            requestedEnd: requestedEnd)
        let clip = Clip(startTime: snapped.start, endTime: snapped.end, text: snapped.text,
                        note: note, createdAt: .now, needsReview: needsReview)
        clip.episode = episode
        episode.clips.append(clip)
        modelContext.insert(clip)
        try? modelContext.save()
        reindex(clip)
        return clip
    }

    @discardableResult
    func quickClip(episode: Episode, at position: TimeInterval) -> Clip {
        makeClip(episode: episode, requestedStart: max(0, position - Self.quickClipWindow),
                 requestedEnd: position, note: nil, needsReview: true)
    }

    func updateNote(_ clip: Clip, note: String?) {
        clip.note = note
        clip.needsReview = false
        try? modelContext.save()
        reindex(clip)
    }

    func delete(_ clip: Clip) {
        if let guid = clip.episode?.guid {
            try? index?.delete(kind: "clip", episodeGuid: guid, startTime: clip.startTime)
        }
        clip.episode?.clips.removeAll { $0 === clip }
        modelContext.delete(clip)
        try? modelContext.save()
    }

    private func reindex(_ clip: Clip) {
        guard let index, let guid = clip.episode?.guid else { return }
        let body = [clip.text, clip.note].compactMap { $0 }.joined(separator: " ")
        try? index.upsert(SearchDoc(kind: "clip", episodeGuid: guid, startTime: clip.startTime, body: body))
    }

    func allClips() -> [Clip] {
        let d = FetchDescriptor<Clip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? modelContext.fetch(d)) ?? []
    }

    func search(_ query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return allClips() }
        return allClips().filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || ($0.note?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}
