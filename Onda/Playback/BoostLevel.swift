//  BoostLevel.swift
import Foundation

enum BoostLevel: Int, Sendable {
    case off = 0, medium = 1, high = 2

    init(clamping raw: Int) { self = BoostLevel(rawValue: max(0, min(2, raw))) ?? .off }

    var gain: Float {
        switch self {
        case .off: return 1.0
        case .medium: return 1.6
        case .high: return 2.4
        }
    }
}
