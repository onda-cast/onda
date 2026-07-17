//  ProfileView.swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppSettings.self) private var appSettings
    var body: some View {
        NavigationStack {
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

                Text("General").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                BrutalCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep transcripts of deleted episodes")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.color(.text))
                            Text("Deleted episodes stay searchable")
                                .font(.system(size: 12)).foregroundStyle(theme.color(.textTertiary))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appSettings.keepTranscriptsOnDelete },
                            set: { appSettings.keepTranscriptsOnDelete = $0 }
                        )).labelsHidden().tint(theme.color(.accent))
                    }
                    .padding(16)
                }
                BrutalCard {
                    NavigationLink(destination: DownloadsStorageView()) {
                        HStack {
                            Text("Downloads & Storage").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.color(.text))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(theme.color(.textTertiary))
                        }
                        .padding(16)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color(.bg))
        }
    }
}
