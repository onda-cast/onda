//  QueueView.swift
import SwiftUI

struct QueueView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var body: some View {
        NavigationStack {
            List {
                if let current = playback.currentEpisode {
                    Section("Now Playing") { row(current, isCurrent: true) }
                }
                Section("Up Next") {
                    if playback.queue.isEmpty {
                        Text("Queue is empty — add episodes from a show or start a smart queue.")
                            .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                    } else {
                        ForEach(playback.queue, id: \.guid) { ep in
                            Button { playback.playFromQueue(ep) } label: { row(ep, isCurrent: false) }
                                .buttonStyle(.plain)
                        }
                        .onMove { playback.moveQueue(from: $0, to: $1) }
                        .onDelete { idx in idx.map { playback.queue[$0] }.forEach(playback.removeFromQueue) }
                    }
                }
            }
            .navigationTitle("Up Next")
            .toolbar { if !playback.queue.isEmpty { EditButton() } }
        }
    }

    private func row(_ ep: Episode, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            if isCurrent {
                Image(systemName: "waveform").scaledFont(14, weight: .bold)
                    .foregroundStyle(theme.color(.accent)).frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title).scaledFont(15, weight: .semibold).lineLimit(2)
                    .foregroundStyle(theme.color(.text))
                Text("\(ep.podcast?.title ?? "") · \(durationText(ep))")
                    .scaledFont(12.5).foregroundStyle(theme.color(.textTertiary)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? "Now playing, \(ep.title)" : "\(ep.title), tap to play next")
    }

    private func durationText(_ ep: Episode) -> String {
        let m = Int(ep.duration) / 60
        return m > 0 ? "\(m) min" : "\(Int(ep.duration))s"
    }
}
