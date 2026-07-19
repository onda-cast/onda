//  EpisodeRow.swift
import SwiftUI

struct EpisodeRow: View {
    @Environment(AppTheme.self) private var theme
    let episode: Episode
    var downloadState: DownloadState = .none
    var snippet: String?
    var onPlay: () -> Void = {}
    var onDownload: () -> Void = {}
    var onOpen: () -> Void = {}

    private var dateText: String {
        episode.publishDate.formatted(.relative(presentation: .named))
    }
    // nil when the feed gives no (or a sub-minute) duration — better to omit than show "0 min".
    private var durationText: String? {
        let m = Int(episode.duration) / 60
        return m > 0 ? "\(m) min" : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                // Replay arrow (not a checkmark) for played episodes: the button STARTS playback,
                // and a checkmark made it read as a played-state toggle. Muted colors still carry
                // the played-ness; the mark-played toggle stays in swipe/context menus.
                Image(systemName: episode.played ? "arrow.counterclockwise" : "play.fill")
                    .scaledFont(14, weight: .black)
                    .foregroundStyle(episode.played ? theme.color(.textTertiary) : .white)
                    .frame(width: 34, height: 34)
                    .background(episode.played ? theme.color(.bgElevated) : theme.color(.accent))
                    .brutalBorder(width: 2)
            }.buttonStyle(.plain)
            .accessibilityIdentifier("play-episode")
            .accessibilityLabel(episode.played ? "Play again" : "Play")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).scaledFont(15, weight: .semibold)
                        .foregroundStyle(theme.color(.text)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(dateText)
                        if let durationText { Text("•"); Text(durationText) }
                        if episode.playbackPosition > 1 && !episode.played {
                            Text("• In progress").foregroundStyle(theme.color(.accent))
                        }
                    }
                    .scaledFont(12.5).foregroundStyle(theme.color(.textTertiary))
                    if let snippet {
                        Text("“\(snippet)”").scaledFont(12.5).italic()
                            .foregroundStyle(theme.color(.textSecondary)).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens episode details")
            Spacer(minLength: 8)
            Button(action: onDownload) {
                downloadIcon
            }.buttonStyle(.plain).accessibilityLabel(downloadAccessibilityLabel)
        }
        .padding(.vertical, 12)
    }

    private var downloadAccessibilityLabel: String {
        switch downloadState {
        case .none: return "Download episode"
        case .downloading(let p): return "Downloading, \(Int(p * 100)) percent"
        case .downloaded: return "Downloaded, delete"
        case .failed: return "Download failed, retry"
        }
    }

    @ViewBuilder private var downloadIcon: some View {
        switch downloadState {
        case .none:
            Image(systemName: "arrow.down")
                .scaledFont(13, weight: .black)
                .foregroundStyle(theme.color(.textSecondary))
                .frame(width: 30, height: 30)
                .background(theme.color(.bgElevated))
                .brutalBorder(width: 2)
        case .downloading(let progress):
            // Square progress: the border fills clockwise — brutal, no circles.
            Rectangle()
                .fill(theme.color(.accentWash))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.color(.accent))
                        .frame(height: max(2, 30 * progress))
                }
                .frame(width: 30, height: 30)
                .brutalBorder(width: 2)
        case .downloaded:
            Image(systemName: "checkmark")
                .scaledFont(13, weight: .black)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(theme.color(.accent))
                .brutalBorder(width: 2)
        case .failed:
            Image(systemName: "arrow.clockwise")
                .scaledFont(13, weight: .black)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black)
                .brutalBorder(width: 2)
        }
    }
}
