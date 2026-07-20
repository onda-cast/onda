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
                ForEach(HiddenCategories.all, id: \.self) { category in
                    categoryRow(category)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color(.bg))
        .navigationTitle("Hidden Categories")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryRow(_ category: String) -> some View {
        let isHidden = hiddenCategories.isHidden(category: category)
        return Button { hiddenCategories.toggle(category) } label: {
            BrutalCard {
                HStack {
                    Text(category).scaledFont(15, weight: .semibold)
                        .foregroundStyle(theme.color(.text))
                    Spacer()
                    if isHidden {
                        Image(systemName: "checkmark").scaledFont(14, weight: .bold)
                            .foregroundStyle(theme.color(.accentStrong))
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category)
        .accessibilityAddTraits(isHidden ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isHidden ? "Hidden. Double-tap to show again."
                                    : "Double-tap to hide from suggestions.")
    }
}
