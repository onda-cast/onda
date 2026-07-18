//  SegmentedRow.swift
import SwiftUI

struct SegmentedRow<T: Hashable>: View {
    @Environment(AppTheme.self) private var theme
    let options: [(label: String, value: T)]
    let selection: T
    var onChange: (T) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { opt in
                let isSelected = opt.value == selection
                Button { onChange(opt.value) } label: {
                    HStack(spacing: 4) {
                        // A shape cue so selection reads without relying on the accent fill alone.
                        if isSelected {
                            Image(systemName: "checkmark").scaledFont(11, weight: .black)
                        }
                        Text(opt.label).scaledFont(13.5, weight: .semibold)
                    }
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4).padding(.vertical, 2)
                    .foregroundStyle(isSelected ? .white : theme.color(.textSecondary))
                    .background(isSelected ? theme.color(.accentStrong) : theme.color(.bg))
                    .brutalBorder(width: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}
