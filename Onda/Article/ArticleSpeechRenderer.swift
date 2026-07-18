//  ArticleSpeechRenderer.swift
import Foundation
import AVFoundation

enum ArticleRenderError: Error, Equatable { case noSentences, synthesisFailed, fileWriteFailed }

struct RenderedArticleAudio: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let cues: [ParsedCue]
}

protocol ArticleSpeechRendering: Sendable {
    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio
}

/// Renders sentences to one AAC (.m4a) file via AVSpeechSynthesizer.write, emitting a
/// sentence-level ParsedCue per utterance from the cumulative frames written. Per-utterance
/// rendering (vs one giant utterance) keeps cue timing exact and failures recoverable.
final class ArticleSpeechRenderer: ArticleSpeechRendering {
    func render(sentences: [String], voiceIdentifier: String?, outputURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedArticleAudio {
        guard !sentences.isEmpty else { throw ArticleRenderError.noSentences }
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        let synthesizer = AVSpeechSynthesizer()
        let voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let sink = AudioFileSink(outputURL: outputURL)
        var cues: [ParsedCue] = []
        cues.reserveCapacity(sentences.count)

        for (i, sentence) in sentences.enumerated() {
            let start = sink.secondsWritten
            try await write(sentence, voice: voice, synthesizer: synthesizer, sink: sink)
            cues.append(ParsedCue(startTime: start, endTime: sink.secondsWritten,
                                  text: sentence, speaker: nil))
            progress(Double(i + 1) / Double(sentences.count))
        }
        sink.close()
        return RenderedArticleAudio(fileURL: outputURL, duration: sink.secondsWritten, cues: cues)
    }

    private func write(_ text: String, voice: AVSpeechSynthesisVoice?,
                       synthesizer: AVSpeechSynthesizer, sink: AudioFileSink) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = OnceFlag()
            synthesizer.write(utterance) { buffer in
                guard !done.isTripped else { return }   // late buffers after an error
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    if done.trip() { cont.resume(throwing: ArticleRenderError.synthesisFailed) }
                    return
                }
                if pcm.frameLength == 0 {   // zero-length buffer marks end of utterance
                    if done.trip() { cont.resume() }
                    return
                }
                do { try sink.append(pcm) } catch {
                    if done.trip() { cont.resume(throwing: ArticleRenderError.fileWriteFailed) }
                }
            }
        }
    }
}

/// Accumulates PCM buffers into one AAC file. The synthesizer delivers buffers serially
/// but on a non-main queue; the lock makes cross-thread access (and Sendable) honest.
private final class AudioFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 22_050

    init(outputURL: URL) { self.outputURL = outputURL }

    var secondsWritten: TimeInterval {
        lock.withLock { Double(frames) / sampleRate }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            if file == nil {   // settings must come from the first real buffer's format
                sampleRate = buffer.format.sampleRate
                file = try AVAudioFile(forWriting: outputURL, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount
                ], commonFormat: buffer.format.commonFormat,
                   interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    func close() { lock.withLock { file = nil } }   // releasing AVAudioFile finalizes the container
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    var isTripped: Bool { lock.withLock { tripped } }

    func trip() -> Bool {
        lock.withLock {
            if tripped { return false }
            tripped = true
            return true
        }
    }
}
