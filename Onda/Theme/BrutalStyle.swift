//  BrutalStyle.swift
import SwiftUI

private struct BrutalBorder: ViewModifier {
    @Environment(AppTheme.self) private var theme
    var width: CGFloat
    func body(content: Content) -> some View {
        content.overlay(Rectangle().stroke(theme.color(.border), lineWidth: width))
    }
}

private struct HardShadow: ViewModifier {
    @Environment(AppTheme.self) private var theme
    var offset: CGFloat
    func body(content: Content) -> some View {
        content.background(
            Rectangle().fill(theme.color(.cardShadow))
                .offset(x: offset, y: offset)
        )
    }
}

extension View {
    func brutalBorder(width: CGFloat = 2.5) -> some View {
        modifier(BrutalBorder(width: width))
    }

    func hardShadow(offset: CGFloat = 4) -> some View {
        modifier(HardShadow(offset: offset))
    }
}

extension Text {
    @MainActor func brutalHeader(size: CGFloat) -> some View {
        self.scaledFont(size, weight: .black, relativeTo: .headline)
            .textCase(.uppercase)
            .tracking(-0.5)
    }
}

struct BrutalCard<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    var offset: CGFloat = 4
    var borderWidth: CGFloat = 2.5
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(theme.color(.bgElevated))
            .brutalBorder(width: borderWidth)
            .hardShadow(offset: offset)
    }
}
