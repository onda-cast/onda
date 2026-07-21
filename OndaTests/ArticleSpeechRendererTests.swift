//  ArticleSpeechRendererTests.swift
import XCTest
import AVFoundation
@testable import Onda

final class ArticleSpeechRendererTests: XCTestCase {
    func test_rendersSentencesToM4AWithMonotonicCues() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }

        let renderer = ArticleSpeechRenderer()
        let result = try await renderer.render(sentences: ["Hello world.", "Goodbye now."],
                                               voiceIdentifier: nil, outputURL: out,
                                               progress: { _ in })

        XCTAssertEqual(result.fileURL, out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].text, "Hello world.")
        XCTAssertEqual(result.cues[0].startTime, 0)
        XCTAssertGreaterThan(result.cues[0].endTime, result.cues[0].startTime)
        XCTAssertGreaterThanOrEqual(result.cues[1].startTime, result.cues[0].endTime)
        XCTAssertEqual(result.duration, result.cues[1].endTime, accuracy: 0.01)
        XCTAssertGreaterThan(result.duration, 0.2, "two spoken sentences can't be near-silent")

        let file = try AVAudioFile(forReading: out)   // decodable AAC container
        XCTAssertGreaterThan(file.length, 0)
    }

    func test_emptySentenceList_throwsNoSentences() async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString).m4a")
        do {
            _ = try await ArticleSpeechRenderer().render(sentences: [], voiceIdentifier: nil,
                                                         outputURL: out, progress: { _ in })
            XCTFail("expected noSentences")
        } catch let e as ArticleRenderError {
            XCTAssertEqual(e, .noSentences)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func test_cancellingRender_throwsCancellationAndLeavesNoFile() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }

        let sentences = (0 ..< 50).map { "This is sentence number \($0), spoken so rendering takes a while." }
        let renderer = ArticleSpeechRenderer()
        let task = Task {
            try await renderer.render(sentences: sentences, voiceIdentifier: nil, outputURL: out,
                                      progress: { _ in })
        }
        // Give the render loop a moment to start (first utterance in flight) before cancelling,
        // so this exercises the mid-render cleanup path rather than a pre-start cancellation.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
