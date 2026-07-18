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
                    Text(opt.label).font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 2)
                        .foregroundStyle(isSelected ? .white : theme.color(.textSecondary))
                        .background(isSelected ? theme.color(.accent) : theme.color(.bg))
                        .brutalBorder(width: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}
