//  LibraryLayout.swift
import SwiftUI

enum LibraryLayout: String, CaseIterable {
    case grid, compact, text
    var label: String {
        switch self {
        case .grid: "Grid"
        case .compact: "Compact"
        case .text: "Text Only"
        }
    }

    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .compact: "rectangle.grid.1x2"
        case .text: "text.justify"
        }
    }
}
