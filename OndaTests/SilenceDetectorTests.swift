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

    func test_soundResets_allowsNextSkip() {
        var d = SilenceDetector()
        var count = 0
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        _ = d.consume(rms: 0.5, bufferSeconds: 0.1)  // loud → reset run
        for _ in 0..<10 { if d.consume(rms: 0.001, bufferSeconds: 0.1) != nil { count += 1 } }
        XCTAssertEqual(count, 2)
    }
}
