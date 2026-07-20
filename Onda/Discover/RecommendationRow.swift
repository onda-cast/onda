//  RecommendationRow.swift
//  One "For You" recommendation: the show row, an on-screen "not interested" ✕, the reason
//  line, swipe-to-hide, and the context-menu secondary paths.
import SwiftUI

struct RecommendationRow: View {
    @Environment(AppTheme.self) private var theme
    let rec: Recommendation
    let isSubscribed: Bool
    let onFollow: () -> Void
    let onPreview: () -> Void
    let onDismiss: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TrendingRow(dto: rec.dto, isSubscribed: isSubscribed, onToggle: onFollow)
                    .contentShape(Rectangle()).onTapGesture(perform: onPreview)
                    .accessibilityHint("Opens a preview of this show")
                // Visible "not interested" — the context menu below stays as the
                // secondary path, but discoverability needs an on-screen control.
                Button(action: onDismiss) {
                    Image(systemName: "xmark").scaledFont(12, weight: .bold)
                        .foregroundStyle(theme.color(.textTertiary))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // See TrendingRow's Follow button for why: guarantees this tap always wins
                // over the ancestor .swipeToHide drag gesture below.
                .highPriorityGesture(TapGesture().onEnded(onDismiss))
                .accessibilityLabel("Not interested in \(rec.dto.collectionName)")
            }
            if let reason = rec.reasonLine {
                Text(reason).scaledFont(11.5).foregroundStyle(theme.color(.textTertiary))
                    .padding(.leading, 2)
            }
        }
        .swipeToHide(onHide)
        .contextMenu {
            Button(role: .destructive, action: onDismiss) {
                Label("Not interested", systemImage: "hand.thumbsdown")
            }
            Button(role: .destructive, action: onHide) {
                Label("Hide from Discover", systemImage: "eye.slash")
            }
        }
    }
}

/// The bottom "…— UNDO" pill both Discover undo flows share (dismissed recommendation, hidden
/// show): tap = undo.
struct UndoToastButton: View {
    @Environment(AppTheme.self) private var theme
    let text: String
    let accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .scaledFont(13.5, weight: .semibold).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(theme.color(.accentStrong)).brutalBorder(width: 2).hardShadow(offset: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, BottomChrome.clearance)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel(accessibility)
    }
}
