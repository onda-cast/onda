//  EpisodeDetailView.swift
//  Full episode surface: complete title, show notes, chapters, and consolidated actions —
//  reachable by tapping an episode row (show notes were previously unreachable).
import SwiftUI

struct EpisodeDetailView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    @State private var showTranscript = false
    @State private var confirmDeleteDownload = false

    private var meta: String {
        let m = Int(episode.duration) / 60
        let dur = m > 0 ? "\(m) min" : "\(Int(episode.duration))s"
        return "\(episode.publishDate.formatted(.dateTime.month().day().year())) · \(dur)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        ArtworkView(url: episode.podcast?.artworkURL, seed: episode.podcast?.title ?? episode.title)
                            .frame(width: 84, height: 84).brutalBorder(width: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.podcast?.title ?? "").font(.system(size: 12, weight: .bold))
                                .textCase(.uppercase).foregroundStyle(theme.color(.accent)).lineLimit(1)
                            Text(episode.title).brutalHeader(size: 18).foregroundStyle(theme.color(.text))
                            Text(meta).font(.system(size: 12.5)).foregroundStyle(theme.color(.textTertiary))
                        }
                    }

                    actions

                    if !episode.chapters.isEmpty { chapters }

                    if !episode.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About This Episode").brutalHeader(size: 13)
                                .foregroundStyle(theme.color(.textTertiary))
                            Text(episode.notes).font(.system(size: 14.5))
                                .foregroundStyle(theme.color(.textSecondary))
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.color(.bg))
            .navigationTitle("Episode").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showTranscript) { TranscriptView(episode: episode) }
            .confirmationDialog("Delete this download?", isPresented: $confirmDeleteDownload,
                                titleVisibility: .visible) {
                Button("Delete Download", role: .destructive) { downloads.delete(episode) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Frees the audio file. You can stream or re-download it later.") }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { playback.play(episode) } label: {
                Label(episode.played ? "Play Again" : "Play", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
            }.buttonStyle(.plain)

            Button { showTranscript = true } label: {
                Image(systemName: "text.quote").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.color(.text))
                    .frame(width: 48, height: 48)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }.buttonStyle(.plain).accessibilityLabel("Transcript")

            Button { downloadAction() } label: {
                Image(systemName: downloadSymbol).font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.color(.text))
                    .frame(width: 48, height: 48)
                    .background(theme.color(.bgElevated)).brutalBorder(width: 2)
            }.buttonStyle(.plain).accessibilityLabel(downloadLabel)
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            ForEach(episode.chapters.sorted { $0.startTime < $1.startTime }, id: \.startTime) { ch in
                HStack {
                    Text(ch.title).font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(theme.color(.text))
                    Spacer()
                    Text(timeStr(ch.startTime)).font(.system(size: 12.5)).monospacedDigit()
                        .foregroundStyle(theme.color(.textTertiary))
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var downloadSymbol: String {
        switch downloads.state(for: episode) {
        case .downloaded: return "checkmark"
        case .downloading: return "arrow.down.circle"
        case .failed: return "arrow.clockwise"
        case .none: return "arrow.down"
        }
    }
    private var downloadLabel: String {
        switch downloads.state(for: episode) {
        case .downloaded: return "Downloaded, delete"
        case .downloading: return "Downloading"
        case .failed: return "Download failed, retry"
        case .none: return "Download episode"
        }
    }
    private func downloadAction() {
        switch downloads.state(for: episode) {
        case .downloaded: confirmDeleteDownload = true
        case .failed: downloads.retryManually(guid: episode.guid)
        case .downloading: break
        case .none: downloads.download(episode)
        }
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
