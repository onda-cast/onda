//  AudioTranscribing.swift
import Foundation

enum TranscriptionError: Error { case unsupportedOS, notAuthorized, noAudioFile }

protocol AudioTranscribing: Sendable {
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ParsedCue]
}

#if canImport(Speech)
import Speech
import AVFoundation

@available(iOS 26, *)
final class SpeechTranscriberEngine: AudioTranscribing {
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [ParsedCue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw TranscriptionError.noAudioFile }

        let transcriber = SpeechTranscriber(locale: .current,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let asset = AVURLAsset(url: fileURL)
        let total = (try? await asset.load(.duration).seconds) ?? 0

        let resultsTask = Task { () -> [ParsedCue] in
            var cues: [ParsedCue] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                let range = result.text.runs.first?.audioTimeRange
                let start = range?.start.seconds ?? 0
                let end = range?.end.seconds ?? start
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    cues.append(ParsedCue(startTime: start, endTime: end, text: text, speaker: nil))
                    if total > 0 { progress(min(1, end / total)) }
                }
            }
            return cues
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultsTask.value
    }
}
#endif
