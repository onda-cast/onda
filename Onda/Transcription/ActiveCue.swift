//  ActiveCue.swift
import Foundation

enum ActiveCue {
    /// Binary search over cues sorted by start time — called on every playback tick,
    /// so it must be O(log n), not O(n) (linear scan over thousands of cues contributed
    /// to a main-thread hang on device).
    static func index(at seconds: TimeInterval, cues: [(start: TimeInterval, end: TimeInterval)]) -> Int? {
        guard let first = cues.first, seconds >= first.start else { return nil }
        var lo = 0, hi = cues.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= seconds { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }
}
