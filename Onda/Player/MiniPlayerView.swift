//  MiniPlayerView.swift
import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var onTap: () -> Void

    var body: some View {
        if let ep = playback.currentEpisode {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ep.title).brutalHeader(size: 14).foregroundStyle(theme.color(.text))
                            .lineLimit(1)
                        Text(ep.podcast?.title ?? "").scaledFont(13.5)
                            .foregroundStyle(theme.color(.textTertiary))
                    }
                    Spacer(minLength: 8)
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .scaledFont(20).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(theme.color(.accent))
                            .brutalBorder(width: 2)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).frame(height: 76)
                .background(theme.color(.sheetBg)).brutalBorder(width: 2.5).hardShadow(offset: 4)
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { geo in
                        Rectangle().fill(theme.color(.accent))
                            .frame(width: max(0, CGFloat(playback.progressFraction)) * geo.size.width, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }.buttonStyle(.plain)
        }
    }
}
