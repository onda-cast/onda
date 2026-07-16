//  SilenceDetector.swift
import Foundation

struct SilenceDetector: Sendable {
    var rmsThreshold: Float = 0.02
    var minSilenceSeconds: Double = 0.6

    struct Skip: Sendable { let seconds: Double }

    private var runSeconds: Double = 0
    private var emittedForRun = false

    mutating func reset() { runSeconds = 0; emittedForRun = false }

    /// Returns a Skip exactly once, when a continuous quiet run first crosses the threshold.
    mutating func consume(rms: Float, bufferSeconds: Double) -> Skip? {
        if rms < rmsThreshold {
            runSeconds += bufferSeconds
            if runSeconds >= minSilenceSeconds && !emittedForRun {
                emittedForRun = true
                return Skip(seconds: runSeconds)
            }
            return nil
        } else {
            runSeconds = 0
            emittedForRun = false
            return nil
        }
    }
}
