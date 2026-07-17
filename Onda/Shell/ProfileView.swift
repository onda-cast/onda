//  ProfileView.swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
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

                    RetentionSettingsSection()

                    Text("General").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    BrutalCard { navRow("Podcast Settings", destination: PodcastSettingsListView()) }
                    BrutalCard { navRow("Downloads & Storage", destination: DownloadsStorageView()) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.color(.bg))
        }
    }

    private func navRow(_ title: String, destination: some View) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.color(.text))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.color(.textTertiary))
            }
            .padding(16)
        }
    }
}
