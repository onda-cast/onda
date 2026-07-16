//  LibraryView.swift
import SwiftUI

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.horizontal, 20).padding(.top, 56)
            Spacer()
            Text("No shows yet").foregroundStyle(theme.color(.textTertiary))
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }
}
