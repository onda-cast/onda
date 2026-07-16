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
                Button { onChange(opt.value) } label: {
                    Text(opt.label).font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(opt.value == selection ? .white : theme.color(.textSecondary))
                        .background(opt.value == selection ? theme.color(.accent) : theme.color(.bg))
                        .brutalBorder(width: 2)
                }.buttonStyle(.plain)
            }
        }
    }
}
