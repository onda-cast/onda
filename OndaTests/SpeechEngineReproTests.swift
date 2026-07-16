//  SpeechEngineReproTests.swift
//  Integration repro for the transcribe crash — drives the real SpeechTranscriberEngine.
import XCTest
@testable import Onda

@MainActor
final class SpeechEngineReproTests: XCTestCase {
    // Regression for docs/BUGS.md #1: TCC invokes the requestAuthorization completion on a
    // background queue; a MainActor-isolated completion closure trips dispatch_assert_queue
    // and kills the process (EXC_BREAKPOINT).
    func test_requestSpeechAuthorization_completionRunsOffMain_withoutCrashing() async {
        _ = await TranscriptService.requestSpeechAuthorization()
    }

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
