//  QueueView.swift
import SwiftUI

struct QueueView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var body: some View {
        NavigationStack {
            List {
                ForEach(playback.queue, id: \.guid) { ep in
                    Button { playback.play(ep) } label: {
                        VStack(alignment: .leading) {
                            Text(ep.title).font(.system(size: 15, weight: .semibold))
                            Text(ep.podcast?.title ?? "").font(.system(size: 12.5))
                                .foregroundStyle(theme.color(.textTertiary))
                        }
                    }
                }
                .onMove { playback.moveQueue(from: $0, to: $1) }
                .onDelete { idx in idx.map { playback.queue[$0] }.forEach(playback.removeFromQueue) }
            }
            .navigationTitle("Up Next")
            .toolbar { EditButton() }
        }
    }
}
