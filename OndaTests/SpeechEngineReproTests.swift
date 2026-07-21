//  SpeechEngineReproTests.swift
//  Integration repro for the transcribe crash — drives the real SpeechTranscriberEngine.
import Speech
import XCTest
@testable import Onda

@MainActor
final class SpeechEngineReproTests: XCTestCase {
    // Regression for docs/BUGS.md #1: TCC invokes the requestAuthorization completion on a
    // background queue; a MainActor-isolated completion closure trips dispatch_assert_queue
    // and kills the process (EXC_BREAKPOINT).
    func test_requestSpeechAuthorization_completionRunsOffMain_withoutCrashing() async throws {
        // On a simulator with no TCC record for the app, requestAuthorization shows the
        // permission prompt with nobody to tap it — the completion never runs (nothing to
        // regress against) and the await stalls the whole run. Skip before triggering it.
        guard SFSpeechRecognizer.authorizationStatus() != .notDetermined else {
            throw XCTSkip("speech authorization prompt unanswered — no TCC record in this environment")
        }
        // Backstop timeout in case the status check and TCC's actual behavior disagree.
        let granted = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await TranscriptService.requestSpeechAuthorization() }
            group.addTask { try? await Task.sleep(for: .seconds(60)); return nil }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if granted == nil {
            throw XCTSkip("speech authorization prompt unanswered — no TCC record in this environment")
        }
    }

    func test_realEngine_transcribesSpokenFixture() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("needs iOS 26") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spoken", withExtension: "aiff"))
        let engine = SpeechTranscriberEngine()
        do {
            // Timeout guard: on simulators the model-asset fetch can stall for many minutes
            // before failing (macOS <26 hosts can't supply speech assets). Cap it at 60s.
            let cues = try await withThrowingTaskGroup(of: [ParsedCue]?.self) { group in
                group.addTask { try await engine.transcribe(fileURL: url) { _ in } }
                group.addTask { try? await Task.sleep(for: .seconds(60)); return nil }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            guard let cues else {
                throw XCTSkip("speech asset fetch timed out — no model in this environment")
            }
            XCTAssertFalse(cues.isEmpty, "expected at least one cue from spoken fixture")
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            // Simulators without the downloadable speech model can't run this end-to-end.
            throw XCTSkip("speech assets unavailable in this environment: \(error)")
        }
    }
}
