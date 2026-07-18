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
                Image(systemName: episode.played ? "checkmark" : "play.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(episode.played ? theme.color(.textTertiary) : .white)
                    .frame(width: 34, height: 34)
                    .background(episode.played ? theme.color(.bgElevated) : theme.color(.accent))
                    .brutalBorder(width: 2)
            }.buttonStyle(.plain)
            .accessibilityIdentifier("play-episode")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.color(.text)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(dateText)
                        if let durationText { Text("•"); Text(durationText) }
                        if episode.playbackPosition > 1 && !episode.played {
                            Text("• In progress").foregroundStyle(theme.color(.accent))
                        }
                    }
                    .font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
                    if let snippet {
                        Text("“\(snippet)”").font(.system(size: 12.5)).italic()
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
                .font(.system(size: 13, weight: .black))
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
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(theme.color(.accent))
                .brutalBorder(width: 2)
        case .failed:
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black)
                .brutalBorder(width: 2)
        }
    }
}
