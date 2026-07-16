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

@Model
final class TranscriptCue {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var transcript: Transcript?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}
