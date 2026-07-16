//  Clip.swift
import Foundation
import SwiftData

@Model
final class Clip {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String          // transcript snapshot at creation; may be empty
    var note: String?
    var createdAt: Date
    var needsReview: Bool     // true for lock-screen quick clips until edited
    var episode: Episode?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String,
         note: String?, createdAt: Date, needsReview: Bool) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.note = note
        self.createdAt = createdAt
        self.needsReview = needsReview
    }
}
