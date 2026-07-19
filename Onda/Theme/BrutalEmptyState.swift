//  BrutalEmptyState.swift
import SwiftUI

/// The single empty-state look for every surface — title + optional detail, one offset —
/// extracted because four hand-rolled versions had drifted in placement and styling.
struct BrutalEmptyState: View {
    @Environment(AppTheme.self) private var theme
    private let title: String
    private let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).scaledFont(14, weight: .semibold)
                .foregroundStyle(theme.color(.textSecondary))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).scaledFont(12)
                    .foregroundStyle(theme.color(.textTertiary))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 48)
    }
}
