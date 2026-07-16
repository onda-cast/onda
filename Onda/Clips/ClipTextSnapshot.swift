//  ClipTextSnapshot.swift
import Foundation

enum ClipTextSnapshot {
    /// Expands the requested range outward to the boundaries of overlapped cues and joins
    /// their text. With no overlapping cues, returns the requested range and empty text.
    static func snap(cues: [(start: TimeInterval, end: TimeInterval, text: String)],
                     requestedStart: TimeInterval,
                     requestedEnd: TimeInterval) -> (start: TimeInterval, end: TimeInterval, text: String) {
        let overlapping = cues
            .filter { $0.end > requestedStart && $0.start < requestedEnd }
            .sorted { $0.start < $1.start }
        guard let first = overlapping.first, let last = overlapping.last else {
            return (requestedStart, requestedEnd, "")
        }
        return (min(first.start, requestedStart), max(last.end, requestedEnd),
                overlapping.map(\.text).joined(separator: " "))
    }
}
