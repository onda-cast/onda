//  BoostLevel.swift
import Foundation

enum BoostLevel: Int, Sendable {
    case off = 0, medium = 1, high = 2

    init(clamping raw: Int) {
        self = BoostLevel(rawValue: max(0, min(2, raw))) ?? .off
    }

    var gain: Float {
        switch self {
        case .off: 1.0
        case .medium: 1.6
        case .high: 2.4
        }
    }
}
