//  BrutalSearchField.swift
import SwiftUI

/// The single search-input surface used across Library search, Discover, and transcript search.
/// One look (brutal border, leading magnifier, inline clear button) and one set of input options,
/// so the three surfaces can't drift apart again. Callers own layout/padding around it.
struct BrutalSearchField: View {
    @Environment(AppTheme.self) private var theme
    private let placeholder: String
    @Binding private var text: String
    private let focus: FocusState<Bool>.Binding?

    init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.focus = focus
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textTertiary))
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.color(.textTertiary))
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}
