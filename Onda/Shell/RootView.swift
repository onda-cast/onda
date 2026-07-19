//  RootView.swift
import SwiftUI

enum Tab: Hashable { case library, discover, profile }

struct RootView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(TranscriptService.self) private var transcripts
    @State private var tab: Tab = .library
    @State private var reviewingQuickClip: Clip?

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
                if !playback.miniPlayerHidden {
                    MiniPlayerView { playback.showNowPlaying = true }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !playback.tabBarHidden {
                    tabBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // App-wide toasts (stacked so they never overlap): clip-capture confirmation and
            // backgrounded-transcription completion.
            VStack(spacing: 8) {
                // Tappable: opens the same Review sheet the in-player scissors flow always
                // forces, so a lock-screen quick-clip and an in-player clip land in the same
                // place instead of one being silent fire-and-forget.
                if let toast = playback.captureToast {
                    toastLabel(toast, action: playback.lastQuickClip.map { clip in
                        { reviewingQuickClip = clip }
                    })
                }
                if let notice = transcripts.completionNotice { toastLabel(notice, action: nil) }
            }
            .padding(.bottom, 150)
        }
        .animation(.easeOut(duration: 0.2), value: playback.captureToast)
        .animation(.easeInOut(duration: 0.25), value: playback.miniPlayerHidden)
        .animation(.easeInOut(duration: 0.25), value: playback.tabBarHidden)
        .animation(.easeOut(duration: 0.2), value: transcripts.completionNotice)
        // Dynamic Type scales the app's fonts (see scaledFont), but cap growth so the brutalist
        // fixed-height controls and two-column grid don't blow out at the largest sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: Binding(get: { playback.showNowPlaying },
                                    set: { playback.showNowPlaying = $0 })) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)   // swipe-down works; the ⌄ button stays the visual affordance
        }
        .sheet(item: $reviewingQuickClip) { ClipReviewSheet(clip: $0) }
    }

    private func toastLabel(_ text: String, action: (() -> Void)?) -> some View {
        Group {
            if let action {
                Button(action: action) { toastContent(text) }.buttonStyle(.plain)
            } else {
                toastContent(text)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toastContent(_ text: String) -> some View {
        BrutalToast(text: text)
    }

    private var tabBar: some View {
        HStack {
            tabButton(.library, "Library", "rectangle.grid.1x2")
            tabButton(.discover, "Discover", "magnifyingglass")
            tabButton(.profile, "Profile", "person")
        }
        .padding(.top, 6)
        .frame(height: 62)
        .background(theme.color(.tabBarBg))
        .overlay(Rectangle().frame(height: 2.5).foregroundStyle(theme.color(.border)), alignment: .top)
    }

    private func tabButton(_ t: Tab, _ label: String, _ icon: String) -> some View {
        let active = tab == t
        // Switching tabs always restores a scroll-hidden mini-player.
        return Button { tab = t; playback.miniPlayerHidden = false } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).scaledFont(20, weight: .semibold)
                Text(label).scaledFont(10.5, weight: .semibold)
            }
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.textTertiary))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
