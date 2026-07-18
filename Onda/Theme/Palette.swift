//  Palette.swift
import SwiftUI

enum Appearance: String { case system, light, dark }

enum ColorToken {
    case bg, bgElevated, text, textSecondary, textTertiary
    case accent, accentWash, separator, border, cardShadow, sheetBg, tabBarBg
    /// A darker accent reserved for small white text/glyphs sitting on a filled accent surface
    /// (e.g. the selected segmented control). In dark mode the standard accent gives white only
    /// ~4.0:1; this variant clears the 4.5:1 AA bar. Identical to `accent` in light mode.
    case accentStrong
}

enum OndaColors {
    // Hex values pre-converted from the prototype's oklch palette.
    private static let light: [ColorToken: String] = [
        .bg: "F2EFE4", .bgElevated: "FFFFFF", .text: "111111",
        .textSecondary: "4A4A44", .textTertiary: "6B6A60",
        .accent: "1F6E4E", .accentWash: "1F6E4E22", .separator: "111111",
        .border: "111111", .cardShadow: "111111", .sheetBg: "FFFFFF", .tabBarBg: "F2EFE4",
        .accentStrong: "1F6E4E"   // light accent is already ~5.6:1 on white
    ]
    private static let dark: [ColorToken: String] = [
        .bg: "111111", .bgElevated: "1E2A24", .text: "FFFFFF",
        .textSecondary: "C3C8C4", .textTertiary: "8A8F8B",
        .accent: "3E8E68", .accentWash: "3E8E6830", .separator: "3A3A3A",
        .border: "FFFFFF", .cardShadow: "FFFFFF", .sheetBg: "161616", .tabBarBg: "111111",
        .accentStrong: "2F7A57"   // darker green → white text hits ~5.2:1 (accent is only ~4.0:1)
    ]

    static func token(_ t: ColorToken, for a: Appearance) -> Color {
        let hex = (a == .light ? light : dark)[t] ?? "FF00FF"
        return Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        var h = hex; var alpha = 1.0
        if h.count == 8 { // RRGGBBAA
            let aa = h.suffix(2)
            alpha = Double(Int(aa, radix: 16) ?? 255) / 255.0
            h = String(h.prefix(6))
        }
        let v = Int(h, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: alpha)
    }
}
