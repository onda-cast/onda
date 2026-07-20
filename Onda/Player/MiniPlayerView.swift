//  MiniPlayerView.swift
import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    var onTap: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        if let ep = playback.currentEpisode {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title, cached: true)
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
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mini-player")
            // Swipe horizontally to close the player: the bar follows the finger and fades,
            // then playback stops and the bar is removed (it won't restore at next launch).
            .offset(x: dragX)
            .opacity(1 - min(0.6, Double(abs(dragX)) / 300))
            // highPriorityGesture: a swipe must not also fire the button's tap (which would
            // open Now Playing mid-dismiss); taps under 20pt of movement still reach the button.
            .highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { value in
                        if abs(value.translation.width) > 100 {
                            withAnimation(.easeOut(duration: 0.18)) {
                                dragX = value.translation.width > 0 ? 500 : -500
                            }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(180))
                                playback.dismissPlayer()
                                dragX = 0
                            }
                        } else {
                            withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                        }
                    }
            )
            .accessibilityAction(named: "Close player") { playback.dismissPlayer() }
        }
    }
}
