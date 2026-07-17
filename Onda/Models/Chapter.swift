//  Chapter.swift
import Foundation
import SwiftData

@Model
final class Chapter {
    var title: String
    var startTime: TimeInterval
    var isAd: Bool
    var source: String        // "feed" | "generated"
    var episode: Episode?

    init(title: String, startTime: TimeInterval, isAd: Bool = false, source: String = "feed") {
        self.title = title
        self.startTime = startTime
        self.isAd = isAd
        self.source = source
    }
}
