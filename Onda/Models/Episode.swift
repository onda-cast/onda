//  Episode.swift
import Foundation
import SwiftData

@Model
final class Episode {
    @Attribute(.unique) var guid: String
    var title: String
    var publishDate: Date
    var duration: TimeInterval
    var audioURL: URL
    var notes: String
    var playbackPosition: TimeInterval
    var played: Bool
    var chaptersURL: URL?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)
    var chapters: [Chapter] = []

    @Relationship(deleteRule: .cascade, inverse: \DownloadedFile.episode)
    var downloadedFile: DownloadedFile?

    init(guid: String, title: String, publishDate: Date, duration: TimeInterval,
         audioURL: URL, notes: String, playbackPosition: TimeInterval = 0, played: Bool = false,
         chaptersURL: URL? = nil) {
        self.chaptersURL = chaptersURL
        self.guid = guid
        self.title = title
        self.publishDate = publishDate
        self.duration = duration
        self.audioURL = audioURL
        self.notes = notes
        self.playbackPosition = playbackPosition
        self.played = played
    }
}
