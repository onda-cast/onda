//  Theme.swift
import SwiftUI

@Observable
final class AppTheme {
    var appearance: Appearance {
        didSet { if persist { UserDefaults.standard.set(appearance.rawValue, forKey: Self.key) } }
    }
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
    func toggle() { appearance = (appearance == .light) ? .dark : .light }
    func color(_ t: ColorToken) -> Color { OndaColors.token(t, for: appearance) }
}
