//  HiddenCategoriesView.swift
//  Settings screen for hiding whole podcast categories from suggestion surfaces (Trending,
//  category browsing, Shake, For You). Doubles as its own picker — unlike HiddenPodcastsView,
//  there's no swipe/context-menu entry point elsewhere to hide a category from.
import SwiftUI

struct HiddenCategoriesView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(HiddenCategories.self) private var hiddenCategories

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hidden from Trending, category browsing, Shake, and For You. "
                    + "Search results aren't affected.")
                    .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                // One card, toggle-per-row, matching the Settings-section convention used
                // throughout Profile (PlaybackSettingsSection/RetentionSettingsSection) — a
                // standard Toggle instead of a checkmark that only appeared for hidden
                // categories, which read backwards against the checkmark = "selected" meaning
                // it carries everywhere else in the app (e.g. Discover's category chips).
                BrutalCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(HiddenCategories.all.enumerated()), id: \.element) { index, category in
                            categoryRow(category)
                            if index < HiddenCategories.all.count - 1 { divider }
                        }
                    }
                    .padding(16)
                }
            }
            .padding(20).padding(.bottom, BottomChrome.clearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color(.bg))
        .navigationTitle("Hidden Categories")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var divider: some View {
        Rectangle().fill(theme.color(.separator)).frame(height: 1).padding(.vertical, 12)
    }

    private func categoryRow(_ category: String) -> some View {
        HStack {
            Text(category).scaledFont(15, weight: .semibold).foregroundStyle(theme.color(.text))
            Spacer()
            Toggle("", isOn: Binding(get: { hiddenCategories.isHidden(category: category) },
                                     set: { _ in hiddenCategories.toggle(category) }))
                .labelsHidden().tint(theme.color(.accent))
                .accessibilityLabel(category)
                .accessibilityHint("Hides this category from Trending, category browsing, Shake, and For You.")
        }
    }
}
