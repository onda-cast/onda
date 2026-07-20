//  HiddenPodcastsView.swift
//  Settings list of shows hidden from Discover (search, trending, recommendations).
//  Unhiding here makes the show reappear everywhere.
import SwiftUI

struct HiddenPodcastsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(HiddenShows.self) private var hidden

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hidden.shows.isEmpty {
                    BrutalEmptyState("No hidden podcasts",
                                     detail: "Swipe a show sideways in Discover to hide it "
                                           + "from search, trending, and recommendations.")
                } else {
                    Text("Hidden from Discover search, trending, and recommendations.")
                        .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                    ForEach(hidden.shows) { show in
                        BrutalCard {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(show.title).scaledFont(15, weight: .bold).lineLimit(2)
                                        .foregroundStyle(theme.color(.text))
                                    if let author = show.author, !author.isEmpty {
                                        Text(author).scaledFont(12)
                                            .foregroundStyle(theme.color(.textTertiary)).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button { hidden.unhide(show.feed) } label: {
                                    Text("UNHIDE").scaledFont(12, weight: .bold)
                                        .foregroundStyle(theme.color(.text))
                                        .padding(.horizontal, 12).frame(height: 36)
                                        .background(theme.color(.bg)).brutalBorder(width: 2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Unhide \(show.title)")
                            }
                            .padding(14)
                        }
                    }
                }
            }
            .padding(20).padding(.bottom, BottomChrome.clearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color(.bg))
        .navigationTitle("Hidden Podcasts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
