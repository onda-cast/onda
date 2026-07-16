//  SleepTimerMenu.swift
import SwiftUI

struct SleepTimerMenu: View {
    @Environment(PlaybackManager.self) private var playback
    var body: some View {
        Menu {
            Button("Off") { playback.setSleepTimer(.off) }
            ForEach([5, 10, 15, 30, 45], id: \.self) { m in
                Button("\(m) min") { playback.setSleepTimer(.duration(TimeInterval(m * 60))) }
            }
            Button("End of episode") { playback.setSleepTimer(.endOfEpisode) }
        } label: {
            Image(systemName: playback.sleepMode == .off ? "moon" : "moon.fill")
                .font(.system(size: 18, weight: .semibold))
        }
    }
}
