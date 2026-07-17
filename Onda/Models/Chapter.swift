//  Chapter.swift
import Foundation
import SwiftData

@Model
final class Chapter {
    var title: String
    var startTime: TimeInterval
    var isAd: Bool
    var source: String = "feed"   // "feed" | "generated"
    var episode: Episode?

    init(title: String, startTime: TimeInterval, isAd: Bool = false) {
        self.title = title
        self.startTime = startTime
        self.isAd = isAd
    }
}
