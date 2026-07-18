//  SeekAccelerator.swift
//  Overcast-style seek acceleration: repeated skip taps in the same direction within a short
//  window multiply the jump (1× → 2× → 4×, capped), so mashing the button covers ground fast.
import Foundation

struct SeekAccelerator {
    static let window: TimeInterval = 2.0
    private var lastTapAt: Date?
    private var lastDirection = 0
    private var multiplierValue = 1.0

    mutating func multiplier(direction: Int, now: Date) -> Double {
        if let last = lastTapAt, direction == lastDirection,
           now.timeIntervalSince(last) <= Self.window {
            multiplierValue = min(4, multiplierValue * 2)
        } else {
            multiplierValue = 1
        }
        lastTapAt = now
        lastDirection = direction
        return multiplierValue
    }
}
