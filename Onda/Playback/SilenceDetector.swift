//  SilenceDetector.swift
import Foundation

struct SilenceDetector: Sendable {
    var rmsThreshold: Float = 0.02
    var minSilenceSeconds: Double = 0.6

    struct Skip: Sendable { let seconds: Double }

    private var runSeconds: Double = 0
    private var emittedForRun = false
    /// Diagnostics: longest quiet run seen since last reset/skip (read by callers for logging).
    private(set) var longestRunSeconds: Double = 0

    mutating func reset() { runSeconds = 0; emittedForRun = false; longestRunSeconds = 0 }

    /// Returns a Skip exactly once, when a continuous quiet run first crosses the threshold.
    mutating func consume(rms: Float, bufferSeconds: Double) -> Skip? {
        if rms < rmsThreshold {
            runSeconds += bufferSeconds
            longestRunSeconds = max(longestRunSeconds, runSeconds)
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
