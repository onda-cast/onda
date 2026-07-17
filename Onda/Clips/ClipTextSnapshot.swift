//  ClipTextSnapshot.swift
import Foundation

/// A span of transcript text: a cue's own [start, end) range, or a clip's requested/snapped range.
struct CueSpan: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum ClipTextSnapshot {
    /// Expands the requested range outward to the boundaries of overlapped cues and joins
    /// their text. With no overlapping cues, returns the requested range and empty text.
    static func snap(cues: [CueSpan], requestedStart: TimeInterval, requestedEnd: TimeInterval) -> CueSpan {
        let overlapping = cues
            .filter { $0.end > requestedStart && $0.start < requestedEnd }
            .sorted { $0.start < $1.start }
        guard let first = overlapping.first, let last = overlapping.last else {
            return CueSpan(start: requestedStart, end: requestedEnd, text: "")
        }
        return CueSpan(start: min(first.start, requestedStart), end: max(last.end, requestedEnd),
                       text: overlapping.map(\.text).joined(separator: " "))
    }
}
