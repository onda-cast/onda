//  ScaledFont.swift
import SwiftUI

/// A system font whose point size scales with the user's Dynamic Type setting (relative to a
/// text style) instead of staying fixed. Growth is capped app-wide (see the `dynamicTypeSize`
/// limit in RootView) so the neo-brutalist layout flexes without breaking.
///
/// Use `.scaledFont(15, weight: .semibold)` in place of `.scaledFont(15, weight: .semibold)`.
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, relativeTo: style))
    }
}
