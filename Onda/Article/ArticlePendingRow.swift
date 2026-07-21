//  ArticlePendingRow.swift
import SwiftUI

/// In-flight conversion row shown at the top of the Articles show's episode list.
/// Backed by ArticleConversionService's ephemeral state, not a real Episode.
struct ArticlePendingRow: View {
    @Environment(AppTheme.self) private var theme
    let item: ArticleConversionService.Pending
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.id.host() ?? item.id.absoluteString)
                .scaledFont(14, weight: .bold).foregroundStyle(theme.color(.text))
                .lineLimit(1)
            if let failure = item.failure {
                Text(failure).scaledFont(13)
                    .foregroundStyle(theme.color(.accent))
                HStack(spacing: 10) {
                    Button("RETRY") { onRetry() }
                    Button("DISMISS") { onDismiss() }
                }
                .scaledFont(12, weight: .bold)
                .foregroundStyle(theme.color(.textSecondary))
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stageLabel).scaledFont(13)
                        .foregroundStyle(theme.color(.textTertiary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2)
    }

    private var stageLabel: String {
        switch item.stage {
        case .fetching: "Fetching article…"
        case let .synthesizing(p): "Synthesizing speech… \(Int(p * 100))%"
        }
    }
}
