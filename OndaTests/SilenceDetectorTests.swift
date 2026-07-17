//  SilenceDetectorTests.swift
import XCTest
@testable import Onda

@MainActor
final class SilenceDetectorTests: XCTestCase {
    func test_shortSilence_doesNotSkip() {
        var d = SilenceDetector()
        // 0.5s total quiet (< 0.6s threshold) across 5 buffers of 0.1s
        for _ in 0..<5 { XCTAssertNil(d.consume(rms: 0.001, bufferSeconds: 0.1)) }
    }

    func test_sustainedSilence_emitsSingleSkip() {
        var d = SilenceDetector()
        var skips: [SilenceDetector.Skip] = []
        for _ in 0..<10 { if let s = d.consume(rms: 0.001, bufferSeconds: 0.1) { skips.append(s) } }
        XCTAssertEqual(skips.count, 1, "one skip per silence run, not per buffer")
        XCTAssertGreaterThanOrEqual(skips[0].seconds, 0.6)
    }

    func test_realSpeechResets_allowsNextSkip() {
        var d = SilenceDetector()
        var count = 0
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        _ = d.consume(rms: 0.5, bufferSeconds: 0.2)  // sustained sound (> blip grace) → reset
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        XCTAssertEqual(count, 2)
    }

    func test_briefBlip_doesNotResetQuietRun() {
        // Real-device finding: breaths/room-tone flickers (<0.15s) between quiet buffers were
        // hard-resetting every run, so skips never fired on actual podcasts.
        var d = SilenceDetector()
        var skips = 0
        for _ in 0..<4 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { skips += 1 } }  // 0.4s quiet
        _ = d.consume(rms: 0.5, bufferSeconds: 0.05)                                            // 50ms blip
        for _ in 0..<3 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { skips += 1 } }  // 0.3s quiet
        XCTAssertEqual(skips, 1, "run should survive a sub-grace blip and reach 0.6s")
    }
}
