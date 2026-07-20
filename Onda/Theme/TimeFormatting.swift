//  TimeFormatting.swift
import Foundation

enum TimeFormatting {
    /// `M:SS` under an hour, `H:MM:SS` at or past it — shared by every screen that shows a
    /// transcript/episode timestamp, so a search hit deep into a long episode reads the same
    /// way (e.g. "1:05:23") wherever it's shown, not "65:23" in one place and "1:05:23" in another.
    static func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
