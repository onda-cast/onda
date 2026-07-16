//  Theme.swift
import SwiftUI

@Observable
final class AppTheme {
    private(set) var appearance: Appearance
    private let persist: Bool
    private static let key = "appearance"

    init(appearance: Appearance? = nil, persist: Bool = true) {
        self.persist = persist
        if let appearance {
            self.appearance = appearance
        } else {
            let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(Appearance.init)
            self.appearance = stored ?? .light
        }
    }

    var colorScheme: ColorScheme { appearance == .dark ? .dark : .light }

    func toggle() { setAppearance(appearance == .light ? .dark : .light) }

    func setAppearance(_ a: Appearance) {
        appearance = a
        if persist { UserDefaults.standard.set(a.rawValue, forKey: Self.key) }
    }

    func color(_ t: ColorToken) -> Color { OndaColors.token(t, for: appearance) }
}
