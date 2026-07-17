//  Transcript.swift
import Foundation
import SwiftData

@Model
final class Transcript {
    var source: String       // "published" | "ondevice"
    var language: String
    var episode: Episode?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptCue.transcript)
    var cues: [TranscriptCue] = []

    init(source: String, language: String) {
        self.source = source
        self.language = language
    }
}

struct WordTiming: Codable, Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

@Model
final class TranscriptCue {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var words: [WordTiming]?   // real per-word timing; only ever set for source == "ondevice"
    var transcript: Transcript?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?,
         words: [WordTiming]? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}
