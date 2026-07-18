//  SleepTimerMenu.swift
import SwiftUI

struct SleepTimerMenu: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Menu {
            row("Off", isOn: playback.sleepMode == .off) { playback.setSleepTimer(.off) }
            ForEach([5, 10, 15, 30, 45], id: \.self) { m in
                row("\(m) min", isOn: playback.sleepMode == .duration(TimeInterval(m * 60))) {
                    playback.setSleepTimer(.duration(TimeInterval(m * 60)))
                }
            }
            row("End of episode", isOn: playback.sleepMode == .endOfEpisode) {
                playback.setSleepTimer(.endOfEpisode)
            }
        } label: {
            // Live remaining time next to the moon while a duration timer is armed.
            HStack(spacing: 4) {
                Image(systemName: playback.sleepMode == .off ? "moon" : "moon.fill")
                    .font(.system(size: 18, weight: .semibold))
                if playback.sleepRemaining != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(remainingText).font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(theme.color(.accent))
                    }
                }
            }
        }
        .accessibilityLabel(playback.sleepMode == .off ? "Sleep timer" : "Sleep timer, \(remainingText) left")
    }

    private var remainingText: String {
        guard let r = playback.sleepRemaining else { return "" }
        let t = Int(r.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    @ViewBuilder private func row(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}
