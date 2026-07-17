//  RootView.swift
import SwiftUI

enum Tab: Hashable { case library, discover, profile }

struct RootView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @State private var tab: Tab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.color(.bg).ignoresSafeArea()
            Group {
                switch tab {
                case .library:  LibraryView()
                case .discover: DiscoverView()
                case .profile:  ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                MiniPlayerView { playback.showNowPlaying = true }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                tabBar
            }
        }
        .sheet(isPresented: Binding(get: { playback.showNowPlaying },
                                    set: { playback.showNowPlaying = $0 })) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)   // swipe-down works; the ⌄ button stays the visual affordance
        }
    }

    private var tabBar: some View {
        HStack {
            tabButton(.library, "Library", "rectangle.grid.1x2")
            tabButton(.discover, "Discover", "magnifyingglass")
            tabButton(.profile, "Profile", "person")
        }
        .padding(.top, 8)
        .frame(height: 78)
        .background(theme.color(.tabBarBg))
        .overlay(Rectangle().frame(height: 2.5).foregroundStyle(theme.color(.border)), alignment: .top)
    }

    private func tabButton(_ t: Tab, _ label: String, _ icon: String) -> some View {
        let active = tab == t
        return Button { tab = t } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.textTertiary))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
