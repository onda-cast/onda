//  ClipRow.swift
import SwiftUI

struct ClipRow: View {
    @Environment(AppTheme.self) private var theme
    let clip: Clip
    var onPlay: () -> Void

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(clip.episode?.podcast?.title ?? "Unknown show")
                    .brutalHeader(size: 12).foregroundStyle(theme.color(.accent))
                if clip.needsReview {
                    Text("NEW").font(.system(size: 10, weight: .black))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.color(.accent)).foregroundStyle(.white)
                }
                Spacer()
                Button(action: onPlay) {
                    Image(systemName: "play.fill").font(.system(size: 14))
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(theme.color(.accent)).brutalBorder(width: 2)
                }.buttonStyle(.plain)
            }
            Text("\(clip.episode?.title ?? "") · \(timeStr(clip.startTime))–\(timeStr(clip.endTime))")
                .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
            if !clip.text.isEmpty {
                Text(clip.text).font(.system(size: 14)).lineLimit(3)
                    .foregroundStyle(theme.color(.textSecondary))
            }
            if let note = clip.note, !note.isEmpty {
                Text(note).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.color(.accent))
            }
        }
        .padding(12)
        .background(theme.color(.bgElevated))
        .brutalBorder(width: 2)
        .hardShadow(offset: 3)
    }
}
