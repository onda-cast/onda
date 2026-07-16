//  DiscoverView.swift
import SwiftUI

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Discover").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.horizontal, 20).padding(.top, 56)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
