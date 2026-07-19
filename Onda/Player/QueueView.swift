//  QueueView.swift
import SwiftUI

struct QueueView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme

    // Keep List (drag-to-reorder + swipe-to-delete come free), but strip its stock chrome and
    // dress every row/section in the app's neo-brutalist style: hard borders, bgElevated cards,
    // brutalHeader section titles, on the theme background.
    var body: some View {
        NavigationStack {
            List {
                if let current = playback.currentEpisode {
                    Section {
                        row(current, isCurrent: true)
                    } header: { sectionHeader("Now Playing") }
                }
                Section {
                    if playback.queue.isEmpty {
                        Text("Queue is empty — add episodes from a show or start a smart queue.")
                            .scaledFont(13).foregroundStyle(theme.color(.textTertiary))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    } else {
                        ForEach(playback.queue, id: \.guid) { ep in
                            Button { playback.playFromQueue(ep) } label: { row(ep, isCurrent: false) }
                                .buttonStyle(.plain)
                        }
                        .onMove { playback.moveQueue(from: $0, to: $1) }
                        .onDelete { idx in idx.map { playback.queue[$0] }.forEach(playback.removeFromQueue) }
                    }
                } header: { sectionHeader("Up Next") }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.color(.bg))
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !playback.queue.isEmpty { EditButton() } }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
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
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? theme.color(.accentWash) : theme.color(.bgElevated))
        .brutalBorder(width: 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? "Now playing, \(ep.title)" : "\(ep.title), tap to play now; other queued episodes stay")
    }

    private func durationText(_ ep: Episode) -> String {
        let m = Int(ep.duration) / 60
        return m > 0 ? "\(m) min" : "\(Int(ep.duration))s"
    }
}
