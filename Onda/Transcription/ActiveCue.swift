//  ActiveCue.swift
import Foundation

enum ActiveCue {
    static func index(at seconds: TimeInterval, cues: [(start: TimeInterval, end: TimeInterval)]) -> Int? {
        guard let first = cues.first, seconds >= first.start else { return nil }
        var result: Int? = nil
        for (i, c) in cues.enumerated() where c.start <= seconds { result = i }
        return result
    }
}
