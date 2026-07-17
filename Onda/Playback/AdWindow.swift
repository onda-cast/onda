//  AdWindow.swift
import Foundation

struct AdWindow: Sendable {
    private let sorted: [(start: TimeInterval, isAd: Bool)]
    private let duration: TimeInterval

    init(chapters: [(start: TimeInterval, isAd: Bool)], duration: TimeInterval) {
        self.sorted = chapters.sorted { $0.start < $1.start }
        self.duration = duration
    }

    private func index(at seconds: TimeInterval) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var idx: Int?
        for (i, c) in sorted.enumerated() where c.start <= seconds { idx = i }
        return idx
    }

    func isAd(at seconds: TimeInterval) -> Bool {
        guard let i = index(at: seconds) else { return false }
        return sorted[i].isAd
    }

    /// If currently inside an ad, the feed-second where the ad ends (next non-ad start, or duration).
    func adEnd(at seconds: TimeInterval) -> TimeInterval? {
        guard let i = index(at: seconds), sorted[i].isAd else { return nil }
        for j in (i + 1)..<sorted.count where !sorted[j].isAd { return sorted[j].start }
        return duration
    }
}
