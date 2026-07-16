//  ProfileView.swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Profile").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.top, 56)

            Text("Appearance").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            BrutalCard {
                HStack {
                    Text("Light / Dark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.color(.text))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { theme.appearance == .dark },
                        set: { _ in theme.toggle() }
                    )).labelsHidden().tint(theme.color(.accent))
                }
                .padding(16)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
