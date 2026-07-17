//  ParsedCue.swift
import Foundation

struct ParsedCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?
    let words: [WordTiming]?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?,
         words: [WordTiming]? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}
