//  Theme.swift
import SwiftUI

@Observable
final class AppTheme {
    /// The user's stored preference: system, light, or dark.
    private(set) var appearance: Appearance
    /// The device's current scheme, fed in by the root view — only consulted when
    /// `appearance == .system`. Keeps colour lookups correct without AppTheme being a View.
    var systemIsDark: Bool
    private let persist: Bool
    private static let key = "appearance"

    init(appearance: Appearance? = nil, persist: Bool = true, systemIsDark: Bool? = nil) {
        self.persist = persist
        if let appearance {
            self.appearance = appearance
        } else {
            let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(Appearance.init)
            self.appearance = stored ?? .system
        }
        self.systemIsDark = systemIsDark ?? (UITraitCollection.current.userInterfaceStyle == .dark)
    }

    /// The concrete light/dark actually used for colours, resolving `.system` to the device scheme.
    var resolvedAppearance: Appearance {
        switch appearance {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// nil for `.system` so SwiftUI follows the device; a fixed scheme otherwise.
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func setAppearance(_ a: Appearance) {
        appearance = a
        if persist { UserDefaults.standard.set(a.rawValue, forKey: Self.key) }
    }

    func color(_ t: ColorToken) -> Color { OndaColors.token(t, for: resolvedAppearance) }
}
