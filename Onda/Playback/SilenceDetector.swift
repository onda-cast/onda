//  SilenceDetector.swift
import Foundation

struct SilenceDetector: Sendable {
    var rmsThreshold: Float = 0.02
    var minSilenceSeconds: Double = 0.6
    /// Brief above-threshold flickers (breaths, room tone, compression pumping) up to this
    /// cumulative duration do NOT reset a quiet run — real-device podcasts never have
    /// digitally clean silence, and hard resets meant skips never fired at all.
    var blipGraceSeconds: Double = 0.15

    struct Skip: Sendable { let seconds: Double }

    private var runSeconds: Double = 0
    private var blipSeconds: Double = 0
    private var emittedForRun = false
    /// Diagnostics: longest quiet run seen since last reset/skip (read by callers for logging).
    private(set) var longestRunSeconds: Double = 0

    mutating func reset() {
        runSeconds = 0; blipSeconds = 0; emittedForRun = false; longestRunSeconds = 0
    }

    /// Returns a Skip exactly once, when a quiet run (tolerant of sub-grace blips) first
    /// crosses the minimum duration.
    mutating func consume(rms: Float, bufferSeconds: Double) -> Skip? {
        if rms < rmsThreshold {
            blipSeconds = 0
            runSeconds += bufferSeconds
            longestRunSeconds = max(longestRunSeconds, runSeconds)
            if runSeconds >= minSilenceSeconds && !emittedForRun {
                emittedForRun = true
                return Skip(seconds: runSeconds)
            }
            return nil
        }
        guard runSeconds > 0 else { return nil }   // loud with no run in progress: nothing to do
        blipSeconds += bufferSeconds
        if blipSeconds > blipGraceSeconds {        // sustained sound: the run is truly over
            runSeconds = 0; blipSeconds = 0; emittedForRun = false
        }
        return nil
    }
}
