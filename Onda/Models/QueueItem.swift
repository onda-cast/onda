//  QueueItem.swift
import Foundation
import SwiftData

@Model
final class QueueItem {
    var position: Int
    var episode: Episode?

    init(episode: Episode, position: Int) {
        self.episode = episode
        self.position = position
    }
}
