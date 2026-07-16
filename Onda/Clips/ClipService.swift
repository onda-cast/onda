//  ClipService.swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ClipService {
    static let quickClipWindow: TimeInterval = 45
    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    @discardableResult
    func makeClip(episode: Episode, requestedStart: TimeInterval, requestedEnd: TimeInterval,
                  note: String?, needsReview: Bool) -> Clip {
        let cues = (episode.transcript?.cues ?? [])
            .sorted { $0.startTime < $1.startTime }
            .map { (start: $0.startTime, end: $0.endTime, text: $0.text) }
        let snapped = ClipTextSnapshot.snap(cues: cues, requestedStart: requestedStart,
                                            requestedEnd: requestedEnd)
        let clip = Clip(startTime: snapped.start, endTime: snapped.end, text: snapped.text,
                        note: note, createdAt: .now, needsReview: needsReview)
        clip.episode = episode
        episode.clips.append(clip)
        modelContext.insert(clip)
        try? modelContext.save()
        return clip
    }

    @discardableResult
    func quickClip(episode: Episode, at position: TimeInterval) -> Clip {
        makeClip(episode: episode, requestedStart: max(0, position - Self.quickClipWindow),
                 requestedEnd: position, note: nil, needsReview: true)
    }

    func delete(_ clip: Clip) {
        clip.episode?.clips.removeAll { $0 === clip }
        modelContext.delete(clip)
        try? modelContext.save()
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
