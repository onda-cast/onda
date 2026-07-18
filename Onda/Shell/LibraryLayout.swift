//  LibraryLayout.swift
import SwiftUI

enum LibraryLayout: String, CaseIterable {
    case grid, compact, text
    var label: String {
        switch self {
        case .grid: return "Grid"
        case .compact: return "Compact"
        case .text: return "Text Only"
        }
    }
    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .compact: return "rectangle.grid.1x2"
        case .text: return "text.justify"
        }
    }
}
