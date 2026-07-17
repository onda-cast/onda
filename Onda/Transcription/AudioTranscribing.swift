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

        // Pick a locale the transcriber actually supports (falls back to en-US).
        let supported = await SpeechTranscriber.supportedLocales
        let locale = supported.first { $0.identifier(.bcp47) == Locale.current.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == Locale.current.language.languageCode }
            ?? Locale(identifier: "en-US")

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // The on-device speech model is a downloadable asset — install it if missing.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let asset = AVURLAsset(url: fileURL)
        let total = (try? await asset.load(.duration).seconds) ?? 0

        let resultsTask = Task { () -> [ParsedCue] in
            var cues: [ParsedCue] = []
            for try await result in transcriber.results {
                let runs = Array(result.text.runs)
                guard !runs.isEmpty else { continue }
                let words: [WordTiming] = runs.compactMap { run in
                    guard let range = run.audioTimeRange else { return nil }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    return WordTiming(text: text, startTime: range.start.seconds, endTime: range.end.seconds)
                }
                let text = String(result.text.characters)
                let start = words.first?.startTime ?? 0
                let end = words.last?.endTime ?? start
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    cues.append(ParsedCue(startTime: start, endTime: end, text: text, speaker: nil,
                                          words: words.isEmpty ? nil : words))
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
