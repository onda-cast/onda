//  ProfileView.swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppTheme.self) private var theme
    @State private var showClips = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Profile").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.top, 56)

                    Text("Appearance").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    BrutalCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Theme").scaledFont(16, weight: .semibold)
                                .foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("System", Appearance.system),
                                                   ("Light", .light), ("Dark", .dark)],
                                         selection: theme.appearance) { theme.setAppearance($0) }
                        }
                        .padding(16)
                    }

                    PlaybackSettingsSection()

                    RetentionSettingsSection()

                    Text("General").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    BrutalCard {
                        Button { showClips = true } label: { row("Saved Clips") }.buttonStyle(.plain)
                    }
                    BrutalCard { navRow("Podcast Settings", destination: PodcastSettingsListView()) }
                    BrutalCard { navRow("Hidden Podcasts", destination: HiddenPodcastsView()) }
                    BrutalCard { navRow("Hidden Categories", destination: HiddenCategoriesView()) }
                    BrutalCard { navRow("Downloads & Storage", destination: DownloadsStorageView()) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, BottomChrome.clearance)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.color(.bg))
            .sheet(isPresented: $showClips) { ClipsView() }
        }
    }

    private func row(_ title: String) -> some View {
        HStack {
            Text(title).scaledFont(16, weight: .semibold)
                .foregroundStyle(theme.color(.text))
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(theme.color(.textTertiary))
        }
        .padding(16)
    }

    private func navRow(_ title: String, destination: some View) -> some View {
        NavigationLink(destination: destination) { row(title) }
    }
}
