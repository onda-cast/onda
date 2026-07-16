//  SpeechEngineReproTests.swift
//  Integration repro for the transcribe crash — drives the real SpeechTranscriberEngine.
import XCTest
@testable import Onda

@MainActor
final class SpeechEngineReproTests: XCTestCase {
    func test_realEngine_transcribesSpokenFixture() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("needs iOS 26") }
        let url = Bundle(for: Self.self).url(forResource: "spoken", withExtension: "aiff")!
        let engine = SpeechTranscriberEngine()
        do {
            let cues = try await engine.transcribe(fileURL: url) { _ in }
            XCTAssertFalse(cues.isEmpty, "expected at least one cue from spoken fixture")
        } catch {
            // Simulators without the downloadable speech model can't run this end-to-end.
            throw XCTSkip("speech assets unavailable in this environment: \(error)")
        }
    }
}
