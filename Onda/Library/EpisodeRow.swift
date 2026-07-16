//  EpisodeRow.swift
import SwiftUI

struct EpisodeRow: View {
    @Environment(AppTheme.self) private var theme
    let episode: Episode
    var onPlay: () -> Void = {}
    var onDownload: () -> Void = {}

    private var dateText: String {
        episode.publishDate.formatted(.relative(presentation: .named))
    }
    private var durationText: String {
        let m = Int(episode.duration) / 60
        return "\(m) min"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: episode.played ? "checkmark.circle" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(episode.played ? theme.color(.textTertiary) : theme.color(.accent))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.color(.text)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(dateText); Text("•"); Text(durationText)
                    if episode.playbackPosition > 1 && !episode.played {
                        Text("• In progress").foregroundStyle(theme.color(.accent))
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
            }
            Spacer(minLength: 8)
            Button(action: onDownload) {
                Image(systemName: episode.downloadedFile == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(theme.color(.textSecondary))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }
}
