//  ClipRow.swift
import SwiftUI

struct ClipRow: View {
    @Environment(AppTheme.self) private var theme
    let clip: Clip
    var onPlay: () -> Void
    var onShare: () -> Void = {}

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(clip.episode?.podcast?.title ?? "Unknown show")
                    .brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                if clip.needsReview {
                    Text("NEW").scaledFont(10, weight: .black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.color(.accentStrong)).foregroundStyle(.white)
                }
                Spacer()
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up").accessibilityLabel("Share clip")
                        .scaledFont(14)
                        .foregroundStyle(theme.color(.text)).frame(width: 32, height: 32)
                        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
                }.buttonStyle(.plain)
                Button(action: onPlay) {
                    Image(systemName: "play.fill").scaledFont(14)
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(theme.color(.accent)).brutalBorder(width: 2)
                }.buttonStyle(.plain)
            }
            Text("\(clip.episode?.title ?? "") · \(timeStr(clip.startTime))–\(timeStr(clip.endTime))")
                .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
            if !clip.text.isEmpty {
                Text(clip.text).scaledFont(14).lineLimit(3)
                    .foregroundStyle(theme.color(.textSecondary))
            }
            if let note = clip.note, !note.isEmpty {
                Text(note).scaledFont(13, weight: .semibold)
                    .foregroundStyle(theme.color(.accent))
            }
        }
        .padding(12)
        .background(theme.color(.bgElevated))
        .brutalBorder(width: 2)
        .hardShadow(offset: 3)
    }
}
